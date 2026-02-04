# digital-ocean-ddns-updater

A small Dynamic DNS (DDNS) updater for **DigitalOcean DNS records**, designed to be run periodically (via `systemd`) to keep an A record updated with your current public IP.

This repository contains **two implementations**:

- **Go version (recommended)** — single static binary, robust and easy to distribute
- **Bash version (legacy)** — POSIX shell script kept for reference

---

## Why the Go version is recommended

- Single static binary (no runtime dependencies)
- Better error handling than shell
- Rate-limit aware
- Easy distribution via GitHub Releases
- Ideal for `systemd` timers

The Bash version remains available for constrained environments, but the Go version is the preferred path.

---

## Features

- Updates DigitalOcean DNS A records
- Automatically detects public IP
- Skips API calls if the IP hasn’t changed
- Safe to run frequently
- Designed for `systemd` (no cron)
- Secrets stored in env files
- Multiple DNS records supported

---

## Installation

Choose **one** of the following options.

---

## Option 1 — Install prebuilt Go binary (recommended)

### Install latest version (stable URL)

Each release publishes stable alias binaries:

- `do-ddns-linux-amd64`
- `do-ddns-linux-arm64`
- `do-ddns-darwin-amd64`
- `do-ddns-darwin-arm64`

This allows a permanent `latest` download URL:

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
```

---

### Install a specific version

```sh
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
```

---

## Option 2 — Build from source

Requires Go ≥ 1.25:

```sh
git clone https://github.com/juanbrny/digital-ocean-ddns-updater.git
cd digital-ocean-ddns-updater

go build -trimpath -ldflags "-s -w" -o do-ddns .
sudo install -m 0755 do-ddns /usr/local/bin/do-ddns
```

---

## Configuration (systemd)

### 1) Create environment file

```sh
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
```

---

### 2) Create systemd service

```ini
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
```

---

### 3) Create systemd timer

```ini
[Unit]
Description=Run DigitalOcean DDNS updater (hq) every 5 minutes

[Timer]
OnCalendar=*:0/5
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
```

---

### 4) Enable and start

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now do-ddns-hq.timer
```

---

## Testing & troubleshooting

Run manually:

```sh
sudo systemctl start do-ddns-hq.service
```

Check timer:

```sh
systemctl status do-ddns-hq.timer
```

View logs:

```sh
journalctl -u do-ddns-hq.service -f
```

---

## Multiple DNS records

To manage multiple records:

- Create one env file per record (`hq`, `vpn`, `nas`)
- Duplicate the service and timer units with different names

Each record runs independently.

---

## Bash implementation (legacy)

The original POSIX shell version (`do-ddns.sh`) is kept for reference and constrained environments.

The Go version is recommended for all new deployments.

---

## License

MIT
