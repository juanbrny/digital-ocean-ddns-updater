# digital-ocean-ddns-updater
DDNS script and systemd timer to update Digital Ocean DNS entries

# Install

## Install script

```sh
sh sudo install -m 0755 do-ddns.sh /usr/local/bin/do-ddns
```

## Environment file, service and timer

This avoids secrets inside unit files.

```sh
# Use env file to avoid inside unit files.

sudo mkdir -p /etc/do-ddns

cat <<EOF > /etc/do-ddns/hq.env
DO_TOKEN=YOUR_DIGITALOCEAN_TOKEN
DO_DOMAIN=johndoe.org
DO_NAME=hq
DO_TTL=30
MAX_RETRIES=6
EOF

sudo chmod 600 /etc/do-ddns/hq.env
sudo chown root:root /etc/do-ddns/hq.env

# Systemd service

cat <<EOF > /etc/systemd/system/do-ddns-hq.service
[Unit]
Description=DigitalOcean DDNS updater
Documentation=https://docs.digitalocean.com/reference/api/api-reference/#tag/Domains
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/do-ddns/hq.env
ExecStart=/usr/local/bin/do-ddns
User=root
Group=root

# Hardening (safe defaults)
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

# Systemd timer

cat <<EOF > /etc/systemd/system/do-ddns-hq.timer
[Unit]
Description=Run DigitalOcean DDNS updater every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Enable timer

sudo systemctl daemon-reload
sudo systemctl enable --now do-ddns-hq.timer
```

Test
```
systemctl status do-ddns-hq.timer
```
Trigger manually (for testing):
```
sudo systemctl start do-ddns-hq.service
```
Check logs
```
journalctl -u do-ddns-hq.service -f
```
