package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const apiBase = "https://api.digitalocean.com/v2"

type Config struct {
	Token     string
	Domain    string
	Name      string
	Type      string
	TTL       int
	IPSource  string
	StateDir  string
	PerPage   int
	MaxRetries int

	CleanupDuplicates bool
	Verbose           bool
}

type DomainRecord struct {
	ID   int64  `json:"id"`
	Type string `json:"type"`
	Name string `json:"name"`
	Data string `json:"data"`
	TTL  int    `json:"ttl"`
}

type listRecordsResponse struct {
	DomainRecords []DomainRecord `json:"domain_records"`
	Links         struct {
		Pages struct {
			Next string `json:"next"`
			Last string `json:"last"`
		} `json:"pages"`
	} `json:"links"`
}

type errorResponse struct {
	ID      string `json:"id"`
	Message string `json:"message"`
}

func logf(format string, args ...any) {
	ts := time.Now().Format("2006-01-02 15:04:05")
	fmt.Fprintf(os.Stderr, "%s %s\n", ts, fmt.Sprintf(format, args...))
}

func mustEnvOrFlag(v string, name string) string {
	if strings.TrimSpace(v) == "" {
		logf("ERROR: %s is required", name)
		os.Exit(2)
	}
	return v
}

func stateFile(cfg Config) string {
	// ensure stable file name
	base := fmt.Sprintf("do-ddns-%s-%s.last_ip", cfg.Domain, cfg.Name)
	return filepath.Join(cfg.StateDir, base)
}

func readLastIP(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	s := strings.TrimSpace(string(b))
	return s, nil
}

func writeLastIP(path, ip string) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(ip+"\n"), 0600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func getPublicIP(ctx context.Context, ipSource string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", ipSource, nil)
	if err != nil {
		return "", err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
	ip := strings.TrimSpace(string(b))
	parsed := net.ParseIP(ip)
	if parsed == nil || parsed.To4() == nil {
		return "", fmt.Errorf("invalid IPv4 from %s: %q", ipSource, ip)
	}
	return ip, nil
}

func doRequest(ctx context.Context, cfg Config, method, url string, body []byte) (
