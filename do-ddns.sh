#!/bin/sh
# DigitalOcean DDNS updater (POSIX sh)
# Updates/creates an A record (e.g., hq.johndoe.org) to your current public IP.
#
# Requirements: curl, awk, sed, grep, mktemp
#
# Configure via environment variables or edit defaults below.

set -eu

: "${DO_TOKEN:=}"              # required
: "${DO_DOMAIN:=}"
: "${DO_NAME:=}"             # record name, e.g., "hq" (not FQDN)
: "${DO_TYPE:=A}"              # only A supported in this script (can extend)
: "${DO_TTL:=30}"             # seconds
: "${IP_SOURCE:=https://api.ipify.org}"   # public IP endpoint
: "${STATE_DIR:=/tmp}"
: "${LOCK_FILE:=$STATE_DIR/do-ddns-${DO_DOMAIN}-${DO_NAME}.lock}"
: "${STATE_FILE:=$STATE_DIR/do-ddns-${DO_DOMAIN}-${DO_NAME}.last_ip}"
: "${MAX_RETRIES:=6}"

API_BASE="https://api.digitalocean.com/v2"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

need() {
  command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing dependency: $1"; exit 1; }
}

need curl
need awk
need sed
need grep
need mktemp

if [ -z "$DO_TOKEN" ]; then
  log "ERROR: DO_TOKEN is not set"
  exit 2
fi

# --- locking to avoid concurrent updates ---
if ( set -o noclobber; : > "$LOCK_FILE" ) 2>/dev/null; then
  trap 'rm -f "$LOCK_FILE"' EXIT INT TERM HUP
else
  log "Another instance is running (lock: $LOCK_FILE). Exiting."
  exit 0
fi

# --- helpers ---
tmpfile() { mktemp "${STATE_DIR%/}/do-ddns.XXXXXX"; }

read_last_ip() {
  if [ -r "$STATE_FILE" ]; then
    awk 'NR==1{gsub(/[[:space:]]+/, "", $0); print; exit}' "$STATE_FILE" 2>/dev/null || true
  else
    echo ""
  fi
}

write_last_ip() {
  ip="$1"
  tmp="$(tmpfile)"
  printf '%s\n' "$ip" > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$STATE_FILE"
}

# HTTP request wrapper with rate-limit handling and retries.
# Writes response body to stdout, and sets global vars:
#   HTTP_CODE, RETRY_AFTER
HTTP_CODE=""
RETRY_AFTER=""

do_request() {
  method="$1"; url="$2"; data="${3:-}"

  attempt=0
  backoff=1

  while :; do
    attempt=$((attempt + 1))

    hdr="$(tmpfile)"
    body="$(tmpfile)"
    # shellcheck disable=SC2064
    trap 'rm -f "$hdr" "$body" "$LOCK_FILE"' EXIT INT TERM HUP

    if [ -n "$data" ]; then
      curl -sS -D "$hdr" -o "$body" -X "$method" "$url" \
        -H "Authorization: Bearer $DO_TOKEN" \
        -H "Content-Type: application/json" \
        --data "$data" || true
    else
      curl -sS -D "$hdr" -o "$body" -X "$method" "$url" \
        -H "Authorization: Bearer $DO_TOKEN" \
        -H "Content-Type: application/json" || true
    fi

    HTTP_CODE="$(awk 'NR==1 {print $2}' "$hdr" 2>/dev/null || echo "")"
    RETRY_AFTER="$(awk 'BEGIN{IGNORECASE=1} /^Retry-After:/ {gsub("\r",""); print $2; exit}' "$hdr" 2>/dev/null || echo "")"

    # Successful (2xx)
    case "$HTTP_CODE" in
      2??)
        cat "$body"
        rm -f "$hdr" "$body"
        return 0
        ;;
      429)
        # Rate limited: honor Retry-After if present, else exponential backoff
        if [ -n "$RETRY_AFTER" ] && echo "$RETRY_AFTER" | grep -Eq '^[0-9]+$'; then
          wait="$RETRY_AFTER"
        else
          wait="$backoff"
        fi

        log "Rate limited (429). Waiting ${wait}s then retrying (attempt $attempt/$MAX_RETRIES)..."
        sleep "$wait"

        backoff=$((backoff * 2))
        if [ "$backoff" -gt 64 ]; then backoff=64; fi

        rm -f "$hdr" "$body"
        ;;
      5??|"")
        # Transient server error or curl issue; backoff and retry
        wait="$backoff"
        log "Transient error (HTTP ${HTTP_CODE:-?}). Waiting ${wait}s then retrying (attempt $attempt/$MAX_RETRIES)..."
        sleep "$wait"
        backoff=$((backoff * 2))
        if [ "$backoff" -gt 64 ]; then backoff=64; fi
        rm -f "$hdr" "$body"
        ;;
      *)
        # Fatal client error
        log "ERROR: HTTP $HTTP_CODE from $url"
        log "Response:"
        sed 's/^/  /' "$body" >&2 || true
        rm -f "$hdr" "$body"
        return 1
        ;;
    esac

    if [ "$attempt" -ge "$MAX_RETRIES" ]; then
      log "ERROR: exceeded max retries ($MAX_RETRIES)"
      return 1
    fi
  done
}

get_public_ip() {
  ip="$(curl -fsS "$IP_SOURCE" 2>/dev/null || true)"
  # Basic IPv4 validation
  if echo "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    echo "$ip"
  else
    log "ERROR: failed to get a valid public IPv4 from $IP_SOURCE (got: ${ip:-<empty>})"
    exit 3
  fi
}

# Extract record id and current data (IP) from the /records response.
# This is a very lightweight JSON parse using sed/awk; it’s sufficient for DO’s stable structure.
# Returns "id|data" or empty if not found.
find_record() {
  json="$1"
  # Split objects by "},{" to get per-record chunks, then match name/type.
  # We look for: "type":"A" and "name":"hq"
  echo "$json" \
    | sed 's/},{/}\n{/g' \
    | awk -v want_type="$DO_TYPE" -v want_name="$DO_NAME" '
        $0 ~ "\"type\":\""want_type"\"" && $0 ~ "\"name\":\""want_name"\"" {
          id=""; data="";
          if (match($0, /"id":[0-9]+/)) { id=substr($0, RSTART+5, RLENGTH-5); }
          if (match($0, /"data":"[^"]+"/)) { data=substr($0, RSTART+8, RLENGTH-9); }
          if (id != "") { print id "|" data; exit; }
        }
      '
}

main() {
  new_ip="$(get_public_ip)"
  log "Public IP detected: $new_ip"

  # --- skip ALL DigitalOcean API calls if IP unchanged since last successful run ---
  last_ip="$(read_last_ip)"
  if [ -n "$last_ip" ] && [ "$last_ip" = "$new_ip" ]; then
    log "IP unchanged since last run ($new_ip). Skipping DigitalOcean API calls."
    exit 0
  fi

  records_json="$(do_request GET "$API_BASE/domains/$DO_DOMAIN/records")" || exit 4

  found="$(find_record "$records_json" || true)"
  record_id="$(printf '%s' "$found" | awk -F'|' '{print $1}')"
  current_ip="$(printf '%s' "$found" | awk -F'|' '{print $2}')"

  if [ -n "$record_id" ]; then
    log "Found existing record: $DO_NAME.$DO_DOMAIN (id=$record_id, current=$current_ip)"
    if [ "$current_ip" = "$new_ip" ]; then
      # Still update the local state so future runs can skip API calls entirely
      write_last_ip "$new_ip"
      log "No update needed (IP unchanged in DigitalOcean)."
      exit 0
    fi

    payload=$(printf '{"data":"%s","ttl":%s}' "$new_ip" "$DO_TTL")
    do_request PUT "$API_BASE/domains/$DO_DOMAIN/records/$record_id" "$payload" >/dev/null
    write_last_ip "$new_ip"
    log "Updated $DO_NAME.$DO_DOMAIN -> $new_ip (ttl=$DO_TTL)"
  else
    log "Record not found. Creating: $DO_TYPE $DO_NAME.$DO_DOMAIN -> $new_ip"
    payload=$(printf '{"type":"%s","name":"%s","data":"%s","ttl":%s}' "$DO_TYPE" "$DO_NAME" "$new_ip" "$DO_TTL")
    do_request POST "$API_BASE/domains/$DO_DOMAIN/records" "$payload" >/dev/null
    write_last_ip "$new_ip"
    log "Created $DO_NAME.$DO_DOMAIN -> $new_ip (ttl=$DO_TTL)"
  fi
}

main "$@"
