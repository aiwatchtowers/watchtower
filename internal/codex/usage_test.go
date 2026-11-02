package codex

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const usageFixture = `{"accountId":"SECRET_ACCOUNT","ordinaryUsageAllowed":false,"rateLimits":{"primary":{"usedPercent":1}},"rateLimitsByLimitId":{"future:bucket":{"limitName":"Future","primary":{"usedPercent":120,"windowDurationMins":10080,"resetsAt":1900000000},"secondary":{"usedPercent":-2,"windowDurationMins":300}},"codex":{"primary":null,"secondary":{"usedPercent":42}}}}`

func usageCode(err error) string {
	var e *UsageError
	if errors.As(err, &e) {
		return e.Code
	}
	return ""
}

func TestReadUsageTranscript(t *testing.T) {
	f := newFakeServer(t, "usage", nil)
	f.env = append(f.env, `WT_USAGE_ACCOUNT={"account":{"type":"chatgpt","email":"SECRET_EMAIL","planType":"pro"}}`, "WT_USAGE_LIMITS="+usageFixture)
	cwdPath := t.TempDir() + "/cwd"
	f.env = append(f.env, "WT_USAGE_CWD="+cwdPath)
	bin, _ := os.Executable()
	got, err := ReadUsage(context.Background(), bin, f.env, "/private/home")
	if err != nil {
		t.Fatal(err)
	}
	cwd, _ := os.ReadFile(cwdPath)
	neutral, _ := filepath.EvalSymlinks(os.TempDir())
	if string(cwd) != neutral {
		t.Fatalf("usage cwd %q", cwd)
	}
	if !got.IdentityKnown || len(got.Scope) != 64 || len(got.Quotas) != 3 || got.OrdinaryUsageAllowed == nil || *got.OrdinaryUsageAllowed {
		t.Fatalf("bad normalized result: %+v", got)
	}
	if got.Quotas[1].UsedPercent != 100 || *got.Quotas[1].DurationMinutes != 10080 || got.Quotas[2].UsedPercent != 0 || *got.Quotas[2].DurationMinutes != 300 {
		t.Fatalf("windows inferred from slot: %+v", got.Quotas)
	}
	b, _ := json.Marshal(got)
	if strings.Contains(string(b), "SECRET") {
		t.Fatalf("identity leaked: %s", b)
	}
	data, err := os.ReadFile(f.log)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	expected := []string{`{"id":1,"jsonrpc":"2.0","method":"initialize","params":{"clientInfo":{"name":"watchtower","version":"1"}}}`, `{"jsonrpc":"2.0","method":"initialized"}`, `{"id":2,"jsonrpc":"2.0","method":"account/read","params":{"refreshToken":false}}`, `{"id":3,"jsonrpc":"2.0","method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}`}
	if len(lines) != len(expected) {
		t.Fatalf("unexpected RPC transcript: %s", data)
	}
	for i := range expected {
		if lines[i] != expected[i] {
			t.Fatalf("RPC %d: got %s want %s", i, lines[i], expected[i])
		}
	}
}

func TestNormalizeUsage(t *testing.T) {
	for _, tt := range []struct {
		name, raw, code string
		count           int
		identity        bool
	}{
		{"legacy", `{"rateLimits":{"limitId":"legacy-future","primary":{"usedPercent":51,"windowDurationMins":300}}}`, "", 1, false},
		{"map preferred", usageFixture, "", 3, true},
		{"null", `null`, "parse", 0, false},
		{"empty", `{}`, "parse", 0, false},
		{"malformed", `{"accountId":"SECRET_ACCOUNT","rateLimits":{"primary":{"usedPercent":"SECRET_TOKEN"}}}`, "parse", 0, true},
		{"missing percent", `{"rateLimits":{"primary":{}}}`, "parse", 0, false},
		{"invalid duration", `{"rateLimits":{"secondary":{"usedPercent":7,"windowDurationMins":0,"resetsAt":0}}}`, "", 1, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			got, err := normalizeUsage([]byte(tt.raw), "home", UsageSnapshot{Quotas: []UsageQuota{}})
			if usageCode(err) != tt.code || len(got.Quotas) != tt.count || got.IdentityKnown != tt.identity {
				t.Fatalf("%+v %v", got, err)
			}
			if strings.Contains(strings.ToUpper(errorText(err)), "SECRET") {
				t.Fatal("error leaks payload")
			}
			if tt.name == "legacy" && got.Quotas[0].Bucket != "legacy-future" {
				t.Fatal("lost legacy bucket identity")
			}
			if tt.name == "invalid duration" && (got.Quotas[0].DurationMinutes != nil || got.Quotas[0].ResetsAt != nil) {
				t.Fatal("fabricated window")
			}
		})
	}
	a, _ := normalizeUsage([]byte(usageFixture), "home-a", UsageSnapshot{})
	b, _ := normalizeUsage([]byte(usageFixture), "home-b", UsageSnapshot{})
	if a.Scope == b.Scope {
		t.Fatal("namespace not isolated")
	}
}
func errorText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func TestReadUsageFailures(t *testing.T) {
	for _, tt := range []struct{ name, mode, account, code string }{
		{"no account", "usage", `{"account":null}`, "no_credentials"},
		{"API key", "usage", `{"account":{"type":"apiKey"}}`, "unsupported_auth"},
		{"unknown auth", "usage", `{"account":{"type":"SECRET"}}`, "unsupported_auth"},
		{"unsupported", "unknown-method", `{}`, "unsupported_cli"},
		{"private server error", "usage-error", `{}`, "network"},
		{"bad account", "usage", `{"account":42}`, "parse"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			f := newFakeServer(t, tt.mode, nil)
			f.env = append(f.env, "WT_USAGE_ACCOUNT="+tt.account)
			bin, _ := os.Executable()
			_, err := ReadUsage(context.Background(), bin, f.env, "home")
			if usageCode(err) != tt.code {
				t.Fatalf("%v", err)
			}
			if strings.Contains(errorText(err), "SECRET") {
				t.Fatal("RPC error leaked")
			}
			data, _ := os.ReadFile(f.log)
			if strings.Contains(string(data), "account/rateLimits/read") {
				t.Fatal("read limits without supported account")
			}
		})
	}
	_, err := ReadUsage(context.Background(), "/nonexistent/codex", nil, "home")
	if usageCode(err) != "cli_missing" {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = ReadUsage(ctx, "/nonexistent/codex", nil, "home")
	if usageCode(err) != "cancelled" {
		t.Fatal(err)
	}
}

func TestReadUsageTimeoutReaps(t *testing.T) {
	f := newFakeServer(t, "hang", nil)
	bin, _ := os.Executable()
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	_, err := ReadUsage(ctx, bin, f.env, "home")
	if usageCode(err) != "timeout" {
		t.Fatalf("%v", err)
	}
}

func TestReadUsageCancellationReaps(t *testing.T) {
	f := newFakeServer(t, "hang", nil)
	bin, _ := os.Executable()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	timer := time.AfterFunc(100*time.Millisecond, cancel)
	defer timer.Stop()
	_, err := ReadUsage(ctx, bin, f.env, "home")
	if usageCode(err) != "cancelled" {
		t.Fatal(err)
	}
}
