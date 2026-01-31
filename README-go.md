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

## Define env vars
```
source /etc/do-ddns/hq.env
```

## Run
```
./do-ddns
```
## Configure systemd timer
````
install -m 0755 do-ddns /usr/local/bin/do-ddns
````
After that, reuse the systemd config from the Bash version