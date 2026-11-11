package codex

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/codex/codextest"
)

const usageFixture = `{"accountId":"SECRET_ACCOUNT","ordinaryUsageAllowed":false,"rateLimits":{"primary":{"usedPercent":1}},"rateLimitsByLimitId":{"future:bucket":{"limitName":"Future","primary":{"usedPercent":120,"windowDurationMins":10080,"resetsAt":1900000000},"secondary":{"usedPercent":-2,"windowDurationMins":300}},"codex":{"primary":null,"secondary":{"usedPercent":42}}}}`

func usageCode(err error) string {
	var e *UsageError
	if errors.As(err, &e) {
		return e.Code
	}
	return ""
}

// usageServer answers the usage conversation: account/read with account,
// account/rateLimits/read with limits.
func usageServer(account, limits json.RawMessage) codextest.Handler {
	return func(m codextest.Message) []any {
		if !isRequest(m) {
			return nil
		}
		switch m.Method {
		case "initialize":
			return []any{notice, codextest.Result(m, map[string]any{"userAgent": "fake/0"})}
		case "account/read":
			return []any{notice, codextest.Result(m, account)}
		case "account/rateLimits/read":
			return []any{codextest.Result(m, limits)}
		}
		return []any{codextest.Error(m, -32601, "Method not found: "+m.Method)}
	}
}

const fakeUsageAccount = `{"account":{"type":"chatgpt","email":"SECRET_EMAIL","planType":"pro"}}`

var usageTranscript = []string{`{"id":1,"jsonrpc":"2.0","method":"initialize","params":{"clientInfo":{"name":"watchtower","version":"1"}}}`, `{"jsonrpc":"2.0","method":"initialized"}`, `{"id":2,"jsonrpc":"2.0","method":"account/read","params":{"refreshToken":false}}`, `{"id":3,"jsonrpc":"2.0","method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}`}

func readFakeUsage(ctx context.Context, s *codextest.Server, home string) (UsageSnapshot, error) {
	return ReadUsageFrom(ctx, func() (AppServerConn, error) { return s.Serve(), nil }, home)
}

func assertUsageResult(t *testing.T, got UsageSnapshot) {
	t.Helper()
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
}

func TestReadUsageTranscript(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		s := codextest.New(usageServer(json.RawMessage(fakeUsageAccount), json.RawMessage(usageFixture)))
		got, err := readFakeUsage(context.Background(), s, "/private/home")
		if err != nil {
			t.Fatal(err)
		}
		assertUsageResult(t, got)
		if s.Killed() {
			t.Fatal("the server was killed instead of exiting at EOF")
		}
		if lines := s.Lines(); !slices.Equal(lines, usageTranscript) {
			t.Fatalf("unexpected RPC transcript:\n%s", strings.Join(lines, "\n"))
		}
	})
}

// The real process: ReadUsage's launcher starts bin in the neutral temp
// folder and the conversation runs over real pipes. Only process events are
// waited on (the answers, the exit at EOF).
func TestReadUsage_ProcessWiring(t *testing.T) {
	cwdPath := filepath.Join(t.TempDir(), "cwd")
	env := append(os.Environ(), fakeModeEnv+"=usage", "WT_USAGE_ACCOUNT="+fakeUsageAccount,
		"WT_USAGE_LIMITS="+usageFixture, "WT_USAGE_CWD="+cwdPath)
	bin, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	got, err := readUsage(context.Background(), usageProcess(bin, env), "/private/home", noBudget)
	if err != nil {
		t.Fatal(err)
	}
	assertUsageResult(t, got)
	cwd, _ := os.ReadFile(cwdPath)
	neutral, _ := filepath.EvalSymlinks(os.TempDir())
	if string(cwd) != neutral {
		t.Fatalf("usage cwd %q", cwd)
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
	for _, tt := range []struct {
		name    string
		handle  codextest.Handler
		account string
		code    string
	}{
		{"no account", nil, `{"account":null}`, "no_credentials"},
		{"API key", nil, `{"account":{"type":"apiKey"}}`, "unsupported_auth"},
		{"unknown auth", nil, `{"account":{"type":"SECRET"}}`, "unsupported_auth"},
		{"unsupported", unknownMethodServer, `{}`, "unsupported_cli"},
		{"private server error", func(m codextest.Message) []any {
			if m.Method == "account/read" {
				return []any{codextest.Error(m, 401, "SECRET_ACCOUNT SECRET_EMAIL SECRET_TOKEN")}
			}
			return usageServer(nil, nil)(m)
		}, `{}`, "network"},
		{"bad account", nil, `{"account":42}`, "parse"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				handle := tt.handle
				if handle == nil {
					handle = usageServer(json.RawMessage(tt.account), json.RawMessage(usageFixture))
				}
				s := codextest.New(handle)
				_, err := readFakeUsage(context.Background(), s, "home")
				if usageCode(err) != tt.code {
					t.Fatalf("%v", err)
				}
				if strings.Contains(errorText(err), "SECRET") {
					t.Fatal("RPC error leaked")
				}
				if strings.Contains(strings.Join(s.Lines(), "\n"), "account/rateLimits/read") {
					t.Fatal("read limits without supported account")
				}
			})
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

// A caller's deadline ends a silent server's conversation as a timeout, at
// that deadline, and the server goes with it.
func TestReadUsageTimeoutReaps(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		s := codextest.New(silentServer)
		s.Linger = true // hung: only a kill ends it
		ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
		defer cancel()
		start := time.Now()
		_, err := readFakeUsage(ctx, s, "home")
		if usageCode(err) != "timeout" {
			t.Fatalf("%v", err)
		}
		if d := time.Since(start); d != 100*time.Millisecond || !s.Killed() {
			t.Fatalf("ended after %s, server killed %v", d, s.Killed())
		}
	})
}

// So does the conversation's own budget, with no caller deadline.
func TestReadUsageBudgetReaps(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		s := codextest.New(silentServer)
		s.Linger = true // hung: only a kill ends it
		start := time.Now()
		_, err := readFakeUsage(context.Background(), s, "home")
		if usageCode(err) != "timeout" {
			t.Fatalf("%v", err)
		}
		if d := time.Since(start); d != appServerBudget || !s.Killed() {
			t.Fatalf("ended after %s, server killed %v", d, s.Killed())
		}
	})
}

func TestReadUsageCancellationReaps(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		s := codextest.New(silentServer)
		s.Linger = true // hung: only a kill ends it
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		errc := make(chan error, 1)
		go func() {
			_, err := readFakeUsage(ctx, s, "home")
			errc <- err
		}()
		synctest.Wait() // the conversation waits for the answer
		cancel()
		if err := <-errc; usageCode(err) != "cancelled" || !s.Killed() {
			t.Fatalf("%v, server killed %v", err, s.Killed())
		}
	})
}

// Complete RPC replies are insufficient: the app-server must also exit within
// the conversation budget, and caller cancellation during Close must survive.
func TestReadUsageCloseFailure(t *testing.T) {
	for _, cancelDuringClose := range []bool{false, true} {
		name := "timeout"
		if cancelDuringClose {
			name = "cancelled"
		}
		t.Run(name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				s := codextest.New(usageServer(json.RawMessage(`{"account":{"type":"chatgpt"}}`), json.RawMessage(usageFixture)))
				s.Linger = true // reads EOF, does not exit
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				type result struct {
					got UsageSnapshot
					err error
				}
				done := make(chan result, 1)
				start := time.Now()
				go func() {
					got, err := readFakeUsage(ctx, s, "home")
					done <- result{got, err}
				}()
				synctest.Wait() // every RPC answered; Close waits for an exit that never comes
				select {
				case <-s.InputEnded():
				default:
					t.Fatal("did not reach Close after successful RPCs")
				}
				if cancelDuringClose {
					cancel()
				}
				r := <-done
				if usageCode(r.err) != name {
					t.Fatalf("Close returned success/wrong error: %+v %v", r.got, r.err)
				}
				if want := map[bool]time.Duration{false: appServerBudget, true: 0}[cancelDuringClose]; time.Since(start) != want {
					t.Fatalf("Close ended after %s, want %s", time.Since(start), want)
				}
				if !s.Killed() {
					t.Fatal("the server that stayed was not killed")
				}
				if !r.got.IdentityKnown || len(r.got.Quotas) != 3 {
					t.Fatal("RPC replies did not complete", r.got)
				}
			})
		})
	}
}
