# digital-ocean-ddns-updater

A small Dynamic DNS (DDNS) updater for **DigitalOcean DNS records**, designed to be run periodically (via `systemd`) to keep an A record updated with your current public IP.

This repository contains **two implementations**:

- ✅ **Go version (recommended)** — single static binary, robust, easy to distribute
- 🧪 **Bash version (legacy)** — POSIX shell script kept for reference

---

## Recommended implementation

👉 **Use the Go version** unless you have a very specific reason not to.

**Why Go?**

- Single static binary (no runtime dependencies)
- No fragile shell parsing
- Better error handling and rate-limit logic
- Easy distribution via GitHub Releases
- Ideal for `systemd` timers

The Bash version remains available but is no longer the preferred path.

---

## Features

- Updates DigitalOcean DNS A records
- Detects public IP automatically
- Skips API calls if IP hasn’t changed
- Rate-limit aware
- Designed for `systemd` (no cron)
- Secrets handled via env files
- Supports multiple DNS records (one unit per record)

---

## Installation

Choose **one** of the following.

---

## Option 1 — Install prebuilt Go binary (recommended)

### A) Install **latest** version (stable URL)

Each release publishes stable alias binaries:

- `do-ddns-linux-amd64`
- `do-ddns-linux-arm64`
- `do-ddns-darwin-amd64`
- `do-ddns-darwin-arm64`

This allows a permanent `latest` URL:

```sh
set -euo pipefail

REPO="juanbrny/digital-ocean-ddns-updater"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

URL="https://github.com/${REPO}/releases/latest/download/do-ddns-${OS}-${ARCH}"

curl -fL -o do-ddns "$URL"
chmod +x do-ddns
sudo install -m 0755 do-ddns /usr/local/bin/do-ddns

B) Install a specific version

set -euo pipefail

REPO="juanbrny/digital-ocean-ddns-updater"
TAG="v0.1.9"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

URL="https://github.com/${REPO}/releases/download/${TAG}/do-ddns-${TAG}-${OS}-${ARCH}"

curl -fL -o do-ddns "$URL"
chmod +x do-ddns
sudo install -m 0755 do-ddns /usr/local/bin/do-ddns

Option 2 — Build Go version from source

Requires Go ≥ 1.25:

git clone https://github.com/juanbrny/digital-ocean-ddns-updater.git
cd digital-ocean-ddns-updater

go build -trimpath -ldflags "-s -w" -o do-ddns .
sudo install -m 0755 do-ddns /usr/local/bin/do-ddns

Configuration (systemd-based)

This setup applies to both implementations, but examples below use the Go binary.
1) Create environment file

Create one env file per DNS record.

sudo mkdir -p /etc/do-ddns

sudo tee /etc/do-ddns/hq.env >/dev/null <<'EOF'
DO_TOKEN=YOUR_DIGITALOCEAN_API_TOKEN
DO_DOMAIN=example.com
DO_NAME=hq
DO_TTL=30
MAX_RETRIES=6
EOF

sudo chmod 600 /etc/do-ddns/hq.env
sudo chown root:root /etc/do-ddns/hq.env

2) Create systemd service

sudo tee /etc/systemd/system/do-ddns-hq.service >/dev/null <<'EOF'
[Unit]
Description=DigitalOcean DDNS updater (hq)
Documentation=https://docs.digitalocean.com/reference/api/api-reference/#tag/Domains
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/do-ddns/hq.env
ExecStart=/usr/local/bin/do-ddns
User=root
Group=root

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/tmp
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF

3) Create systemd timer

sudo tee /etc/systemd/system/do-ddns-hq.timer >/dev/null <<'EOF'
[Unit]
Description=Run DigitalOcean DDNS updater (hq) every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

4) Enable and start

sudo systemctl daemon-reload
sudo systemctl enable --now do-ddns-hq.timer

Testing & troubleshooting

Run once manually:

sudo systemctl start do-ddns-hq.service

Check timer:

systemctl status do-ddns-hq.timer

View logs:

journalctl -u do-ddns-hq.service -f

Multiple DNS records

To manage multiple records:

    Create one env file per record:

        /etc/do-ddns/vpn.env

        /etc/do-ddns/nas.env

    Duplicate service/timer units:

        do-ddns-vpn.service

        do-ddns-vpn.timer

Each record runs independently.
Bash implementation (legacy)

The original POSIX shell implementation is still available:

    Script: do-ddns.sh

    Documentation: see previous history or older README sections

It is kept for reference and constrained environments, but the Go version is preferred.
License

MIT


---

If you want next steps, I can:

- Add a **migration guide** (Bash → Go)
- Add a **security rationale** section
- Slim it down into a **short README + docs/** split
- Add badges (build, release, Go version)

Just say the word.
