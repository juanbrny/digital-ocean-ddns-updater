# Install

## Install go

On SUSE based servers

```
zypper in go
go version
```

## Build go app
```
go build -o do-ddns ./do-ddns.go
```

## Download app
If you don't want to setup a go build env locally, just pick the binary version that matches your architecture:
````
curl -fsSL https://github.com/juanbrny/digital-ocean-ddns-updater/releases/latest/download/do-ddns-$(uname -s | tr A-Z a-z)-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') -o do-ddns && chmod +x do-ddns
install -m 0755 do-ddns /usr/local/bin/do-ddns
```

## Define env vars
```
set -a
. /etc/do-ddns/hq.env
set +a
```

## Run
```
./do-ddns
```
## Configure systemd timer
Reuse the systemd config from the Bash versiongit push origin v0.1.0