#!/bin/sh
# DigitalOcean DDNS updater (POSIX sh)
# Robust against JSON whitespace + pagination; avoids creating duplicates.
#
# Requirements: curl, awk, sed, grep, mktemp

set -eu

: "${DO_TOKEN:=}"              # required
: "${DO_DOMAIN:=}"
: "${DO_NAME:=}"             # record name, e.g., "hq" (not FQDN)
: "${DO_TYPE:=A}"
: "${DO_TTL:=300}"
: "${IP_SOURCE:=https://api.ipify.org}"
: "${STATE_DIR:=/tmp}"
: "${LOCK_FILE:=$STATE_DIR/do-ddns-${DO_DOMAIN}-${DO_NAME}.lock}"
: "${STATE_FILE:=$STATE_DIR/do-ddns-${DO_DOMAIN}-${DO_NAME}.last_ip}"
: "${MAX_RETRIES:=6}"
: "${PER_PAGE:=200}"

API_BASE="https://api.digitalocean.com/v2"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing dependency: $1"; exit 1; }; }

need curl; need awk; need sed; need grep; need mktemp

[ -n "$DO_TOKEN" ] || { log "ERROR: DO_TOKEN is not set"; exit 2; }

# lock (avoid concurrent runs creating / updating simultaneously)
if ( set -o noclobber; : > "$LOCK_FILE" ) 2>/dev/null; then
  trap 'rm -f "$LOCK_FILE"' EXIT INT TERM HUP
else
  log "Another instance is running (lock: $LOCK_FILE). Exiting."
  exit 0
fi

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

    case "$HTTP_CODE" in
      2??)
        cat "$body"
        rm -f "$hdr" "$body"
        return 0
        ;;
      429)
        if [ -n "$RETRY_AFTER" ] && echo "$RETRY_AFTER" | grep -Eq '^[0-9]+$'; then
          wait="$RETRY_AFTER"
        else
          wait="$backoff"
        fi
        log "Rate limited (429). Waiting ${wait}s then retrying (attempt $attempt/$MAX_RETRIES)..."
        sleep "$wait"
        backoff=$((backoff * 2)); [ "$backoff" -gt 64 ] && backoff=64
        rm -f "$hdr" "$body"
        ;;
      5??|"")
        wait="$backoff"
        log "Transient error (HTTP ${HTTP_CODE:-?}). Waiting ${wait}s then retrying (attempt $attempt/$MAX_RETRIES)..."
        sleep "$wait"
        backoff=$((backoff * 2)); [ "$backoff" -gt 64 ] && backoff=64
        rm -f "$hdr" "$body"
        ;;
      *)
        log "ERROR: HTTP $HTTP_CODE from $url"
        log "Response:"
        sed 's/^/  /' "$body" >&2 || true
        rm -f "$hdr" "$body"
        return 1
        ;;
    esac

    [ "$attempt" -lt "$MAX_RETRIES" ] || { log "ERROR: exceeded max retries ($MAX_RETRIES)"; return 1; }
  done
}

get_public_ip() {
  ip="$(curl -fsS "$IP_SOURCE" 2>/dev/null || true)"
  if echo "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    echo "$ip"
  else
    log "ERROR: failed to get a valid public IPv4 from $IP_SOURCE (got: ${ip:-<empty>})"
    exit 3
  fi
}

# Extract "next" URL (whitespace tolerant)
extract_next_url() {
  # prints first match of next URL or empty
  printf '%s' "$1" | tr '\n' ' ' | sed -n 's/.*"next"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | awk 'NR==1{print; exit}'
}

# Parse one JSON page and output ALL matching records as lines: id|data
# Tolerant to whitespace: "type": "A", etc.
find_all_matching_records_in_page() {
  json="$1"

  # Split objects by "},{" which is present in the domain_records array;
  # then on each object-line, extract id/type/name/data with whitespace-tolerant regex.
  printf '%s' "$json" \
    | tr '\n' ' ' \
    | sed 's/},{/}\n{/g' \
    | awk -v want_type="$DO_TYPE" -v want_name="$DO_NAME" '
      function field(re,   m) { if (match($0, re, m)) return m[1]; return ""; }
      {
        # Only consider objects that look like a record (have "id" and "type" and "name")
        id   = field(/"id"[[:space:]]*:[[:space:]]*([0-9]+)/, m)
        type = field(/"type"[[:space:]]*:[[:space:]]*"([^"]+)"/, m)
        name = field(/"name"[[:space:]]*:[[:space:]]*"([^"]+)"/, m)
        data = field(/"data"[[:space:]]*:[[:space:]]*"([^"]+)"/, m)

        if (id != "" && type == want_type && name == want_name) {
          print id "|" data
        }
      }
    '
}

# Iterate all pages, collect all matching A records for DO_NAME.
# Output multiple lines: id|data
find_all_matching_records() {
  url="$API_BASE/domains/$DO_DOMAIN/records?per_page=$PER_PAGE&page=1"
  while :; do
    json="$(do_request GET "$url")" || return 1
    find_all_matching_records_in_page "$json" || true
    next="$(extract_next_url "$json" || true)"
    [ -n "$next" ] || break
    url="$next"
  done
  return 0
}

main() {
  new_ip="$(get_public_ip)"
  log "Public IP detected: $new_ip"

  # Skip ALL DO API calls if IP unchanged since last successful run
  last_ip="$(read_last_ip)"
  if [ -n "$last_ip" ] && [ "$last_ip" = "$new_ip" ]; then
    log "IP unchanged since last run ($new_ip). Skipping DigitalOcean API calls."
    exit 0
  fi

  # Collect all matching records (avoid duplicates by never POSTing if any exist)
  matches="$(find_all_matching_records || true)"

  if [ -n "$matches" ]; then
    # Choose the lowest record id for stability
    chosen="$(printf '%s\n' "$matches" | awk -F'|' '
      NR==1 {min=$1; data=$2}
      $1 < min {min=$1; data=$2}
      END { if (min!="") print min "|" data }
    ')"
    record_id="$(printf '%s' "$chosen" | awk -F'|' '{print $1}')"
    current_ip="$(printf '%s' "$chosen" | awk -F'|' '{print $2}')"
    count="$(printf '%s\n' "$matches" | awk 'NF{c++} END{print c+0}')"

    log "Found $count existing $DO_TYPE record(s) for $DO_NAME.$DO_DOMAIN. Using id=$record_id (current=$current_ip)."

    if [ "$current_ip" = "$new_ip" ]; then
      write_last_ip "$new_ip"
      log "No update needed (IP unchanged in DigitalOcean)."
      exit 0
    fi

    payload=$(printf '{"data":"%s","ttl":%s}' "$new_ip" "$DO_TTL")
    do_request PUT "$API_BASE/domains/$DO_DOMAIN/records/$record_id" "$payload" >/dev/null
    write_last_ip "$new_ip"
    log "Updated $DO_NAME.$DO_DOMAIN -> $new_ip (ttl=$DO_TTL)"
    exit 0
  fi

  # No record exists at all -> create exactly once
  log "No existing $DO_TYPE record found for $DO_NAME.$DO_DOMAIN. Creating it."
  payload=$(printf '{"type":"%s","name":"%s","data":"%s","ttl":%s}' "$DO_TYPE" "$DO_NAME" "$new_ip" "$DO_TTL")
  do_request POST "$API_BASE/domains/$DO_DOMAIN/records" "$payload" >/dev/null
  write_last_ip "$new_ip"
  log "Created $DO_NAME.$DO_DOMAIN -> $new_ip (ttl=$DO_TTL)"
}

main "$@"
