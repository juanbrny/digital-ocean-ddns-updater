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

func doRequest(ctx context.Context, cfg Config, method, url string, body []byte) ([]byte, int, http.Header, error) {
	var lastErr error
	backoff := 1 * time.Second

	for attempt := 1; attempt <= cfg.MaxRetries; attempt++ {
		var r io.Reader
		if body != nil {
			r = bytes.NewReader(body)
		}

		req, err := http.NewRequestWithContext(ctx, method, url, r)
		if err != nil {
			return nil, 0, nil, err
		}
		req.Header.Set("Authorization", "Bearer "+cfg.Token)
		req.Header.Set("Content-Type", "application/json")

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			lastErr = err
			logf("Transient error: %v (attempt %d/%d), backoff %s", err, attempt, cfg.MaxRetries, backoff)
			time.Sleep(backoff)
			backoff = minDuration(backoff*2, 64*time.Second)
			continue
		}

		hdr := resp.Header.Clone()
		status := resp.StatusCode
		data, _ := io.ReadAll(resp.Body)
		resp.Body.Close()

		// Success
		if status >= 200 && status <= 299 {
			return data, status, hdr, nil
		}

		// Rate limit
		if status == 429 {
			wait := backoff
			if ra := hdr.Get("Retry-After"); ra != "" {
				if n, err := strconv.Atoi(strings.TrimSpace(ra)); err == nil && n > 0 {
					wait = time.Duration(n) * time.Second
				}
			}
			logf("Rate limited (429). Waiting %s then retrying (attempt %d/%d)...", wait, attempt, cfg.MaxRetries)
			time.Sleep(wait)
			backoff = minDuration(backoff*2, 64*time.Second)
			lastErr = fmt.Errorf("rate limited")
			continue
		}

		// Retry 5xx
		if status >= 500 && status <= 599 {
			logf("Server error (HTTP %d). Waiting %s then retrying (attempt %d/%d)...", status, backoff, attempt, cfg.MaxRetries)
			time.Sleep(backoff)
			backoff = minDuration(backoff*2, 64*time.Second)
			lastErr = fmt.Errorf("server error http %d", status)
			continue
		}

		// Non-retryable
		msg := strings.TrimSpace(string(data))
		// try to decode DO error message
		var er errorResponse
		if json.Unmarshal(data, &er) == nil && er.Message != "" {
			msg = er.Message
		}
		return data, status, hdr, fmt.Errorf("HTTP %d: %s", status, msg)
	}

	return nil, 0, nil, fmt.Errorf("exceeded max retries (%d): last error: %v", cfg.MaxRetries, lastErr)
}

func minDuration(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}

func listAllRecords(ctx context.Context, cfg Config) ([]DomainRecord, error) {
	var out []DomainRecord

	url := fmt.Sprintf("%s/domains/%s/records?per_page=%d&page=1", apiBase, cfg.Domain, cfg.PerPage)
	for {
		b, _, _, err := doRequest(ctx, cfg, "GET", url, nil)
		if err != nil {
			return nil, err
		}
		var resp listRecordsResponse
		if err := json.Unmarshal(b, &resp); err != nil {
			return nil, fmt.Errorf("failed to parse list records response: %w", err)
		}
		out = append(out, resp.DomainRecords...)
		next := strings.TrimSpace(resp.Links.Pages.Next)
		if next == "" {
			break
		}
		url = next
	}
	return out, nil
}

func createRecord(ctx context.Context, cfg Config, ip string) error {
	payload := map[string]any{
		"type": cfg.Type,
		"name": cfg.Name,
		"data": ip,
		"ttl":  cfg.TTL,
	}
	b, _ := json.Marshal(payload)
	_, _, _, err := doRequest(ctx, cfg, "POST", fmt.Sprintf("%s/domains/%s/records", apiBase, cfg.Domain), b)
	return err
}

func updateRecord(ctx context.Context, cfg Config, id int64, ip string) error {
	payload := map[string]any{
		"data": ip,
		"ttl":  cfg.TTL,
	}
	b, _ := json.Marshal(payload)
	_, _, _, err := doRequest(ctx, cfg, "PUT", fmt.Sprintf("%s/domains/%s/records/%d", apiBase, cfg.Domain, id), b)
	return err
}

func deleteRecord(ctx context.Context, cfg Config, id int64) error {
	_, _, _, err := doRequest(ctx, cfg, "DELETE", fmt.Sprintf("%s/domains/%s/records/%d", apiBase, cfg.Domain, id), nil)
	return err
}

func main() {
	var cfg Config
	flag.StringVar(&cfg.Token, "token", os.Getenv("DO_TOKEN"), "DigitalOcean API token (or env DO_TOKEN)")
	flag.StringVar(&cfg.Domain, "domain", os.Getenv("DO_DOMAIN"), "Domain (or env DO_DOMAIN)")
	flag.StringVar(&cfg.Name, "name", os.Getenv("DO_NAME"), "Record name (relative, e.g. hq) (or env DO_NAME)")
	flag.StringVar(&cfg.Type, "type", envDefault("DO_TYPE", "A"), "Record type (A/AAAA/CNAME/etc) (or env DO_TYPE)")
	flag.IntVar(&cfg.TTL, "ttl", envDefaultInt("DO_TTL", 300), "TTL seconds (or env DO_TTL)")
	flag.StringVar(&cfg.IPSource, "ip-source", envDefault("IP_SOURCE", "https://api.ipify.org"), "Public IP source URL (or env IP_SOURCE)")
	flag.StringVar(&cfg.StateDir, "state-dir", envDefault("STATE_DIR", "/tmp"), "State directory (or env STATE_DIR)")
	flag.IntVar(&cfg.PerPage, "per-page", envDefaultInt("PER_PAGE", 200), "Per-page pagination size (or env PER_PAGE)")
	flag.IntVar(&cfg.MaxRetries, "max-retries", envDefaultInt("MAX_RETRIES", 6), "Max retries for DO API calls (or env MAX_RETRIES)")
	flag.BoolVar(&cfg.CleanupDuplicates, "cleanup-duplicates", false, "If set, delete duplicate matching records (keeps lowest ID)")
	flag.BoolVar(&cfg.Verbose, "v", false, "Verbose logging")
	flag.Parse()

	cfg.Token = mustEnvOrFlag(cfg.Token, "DO_TOKEN / --token")
	cfg.Domain = mustEnvOrFlag(cfg.Domain, "DO_DOMAIN / --domain")
	cfg.Name = mustEnvOrFlag(cfg.Name, "DO_NAME / --name")
	if cfg.Type == "" {
		cfg.Type = "A"
	}

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	// 1) detect IP
	newIP, err := getPublicIP(ctx, cfg.IPSource)
	if err != nil {
		logf("ERROR: %v", err)
		os.Exit(3)
	}
	logf("Public IP detected: %s", newIP)

	// 2) skip DO calls if state says unchanged
	
	sf := stateFile(cfg)
	/*
	Disabled for now, we want to always update the record as we'll never reach Digital Ocean's API rate limit. 
	lastIP, err := readLastIP(sf)
	*/
	/*
	if err != nil {
		logf("WARN: failed reading state file: %v", err)
	}
	if lastIP != "" && lastIP == newIP {
		logf("IP unchanged since last run (%s). Skipping DigitalOcean API calls.", newIP)
		return
	}
	*/

	// 3) list all records and filter
	recs, err := listAllRecords(ctx, cfg)
	if err != nil {
		logf("ERROR: listing records: %v", err)
		os.Exit(4)
	}

	var matches []DomainRecord
	for _, r := range recs {
		if r.Type == cfg.Type && r.Name == cfg.Name {
			matches = append(matches, r)
		}
	}

	if len(matches) == 0 {
		logf("No existing %s record found for %s.%s. Creating it.", cfg.Type, cfg.Name, cfg.Domain)
		if err := createRecord(ctx, cfg, newIP); err != nil {
			logf("ERROR: create record: %v", err)
			os.Exit(5)
		}
		if err := writeLastIP(sf, newIP); err != nil {
			logf("WARN: failed writing state file: %v", err)
		}
		logf("Created %s.%s -> %s (ttl=%d)", cfg.Name, cfg.Domain, newIP, cfg.TTL)
		return
	}

	// sort by ID and pick canonical
	sort.Slice(matches, func(i, j int) bool { return matches[i].ID < matches[j].ID })
	chosen := matches[0]

	logf("Found %d existing %s record(s) for %s.%s. Using id=%d (current=%s).",
		len(matches), cfg.Type, cfg.Name, cfg.Domain, chosen.ID, chosen.Data)

	if chosen.Data == newIP {
		// Update state anyway so we stop calling DO next time
		if err := writeLastIP(sf, newIP); err != nil {
			logf("WARN: failed writing state file: %v", err)
		}
		logf("No update needed (IP unchanged in DigitalOcean).")
		// Optionally cleanup duplicates even if IP unchanged
		if cfg.CleanupDuplicates && len(matches) > 1 {
			if err := cleanup(ctx, cfg, matches[1:]); err != nil {
				logf("WARN: cleanup duplicates failed: %v", err)
			}
		}
		return
	}

	// 4) Update canonical record only
	if err := updateRecord(ctx, cfg, chosen.ID, newIP); err != nil {
		logf("ERROR: update record id=%d: %v", chosen.ID, err)
		os.Exit(6)
	}
	if err := writeLastIP(sf, newIP); err != nil {
		logf("WARN: failed writing state file: %v", err)
	}
	logf("Updated %s.%s -> %s (ttl=%d)", cfg.Name, cfg.Domain, newIP, cfg.TTL)

	// 5) Optional cleanup duplicates after successful update
	if cfg.CleanupDuplicates && len(matches) > 1 {
		if err := cleanup(ctx, cfg, matches[1:]); err != nil {
			logf("WARN: cleanup duplicates failed: %v", err)
		}
	}
}

func cleanup(ctx context.Context, cfg Config, dups []DomainRecord) error {
	if len(dups) == 0 {
		return nil
	}
	logf("Cleanup enabled: deleting %d duplicate record(s)...", len(dups))
	var errs []string
	for _, r := range dups {
		if err := deleteRecord(ctx, cfg, r.ID); err != nil {
			errs = append(errs, fmt.Sprintf("id=%d: %v", r.ID, err))
			continue
		}
		logf("Deleted duplicate record id=%d (data=%s)", r.ID, r.Data)
	}
	if len(errs) > 0 {
		return errors.New(strings.Join(errs, "; "))
	}
	return nil
}

func envDefault(key, def string) string {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return def
	}
	return v
}

func envDefaultInt(key string, def int) int {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}
