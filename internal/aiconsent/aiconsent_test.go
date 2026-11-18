package aiconsent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
)

type consentCase struct {
	Name      string          `json:"name"`
	Answer    *string         `json:"answer"`
	PolicyRaw json.RawMessage `json:"policy_raw"`
	Want      struct {
		Effective string `json:"effective"`
		Reason    string `json:"reason"`
		Prompt    bool   `json:"prompt"`
		Locked    bool   `json:"locked"`
	} `json:"want"`
}

func TestBGAI03_SharedFixture(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "consent_cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var cases []consentCase
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) != 8 {
		t.Fatalf("fixture has %d rows, spec §3.2 has 8", len(cases))
	}
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			raw := map[string]any{}
			if len(c.PolicyRaw) > 0 {
				var v any
				if err := json.Unmarshal(c.PolicyRaw, &v); err != nil {
					t.Fatal(err)
				}
				raw[policy.KeyAllowBackgroundAI] = v
			}
			answerRaw := ""
			if c.Answer != nil {
				answerRaw = *c.Answer
			}
			a, _ := ParseAnswer(answerRaw)
			got := Resolve(a, policy.Normalize(raw).Keys.AllowBackgroundAI)
			if string(got.Effective) != c.Want.Effective || string(got.Reason) != c.Want.Reason ||
				got.Prompt != c.Want.Prompt || got.Locked != c.Want.Locked {
				t.Fatalf("got %+v, want %+v", got, c.Want)
			}
			if got.Allowed() != (c.Want.Effective == "allowed") {
				t.Fatalf("Allowed() = %v for effective %q", got.Allowed(), c.Want.Effective)
			}
		})
	}
}

func TestParseAnswer(t *testing.T) {
	for raw, want := range map[string]struct {
		a     Answer
		known bool
	}{
		"":        {AnswerNone, true},
		"allowed": {AnswerAllowed, true},
		"paused":  {AnswerPaused, true},
		"yes":     {AnswerNone, false},
		"Allowed": {AnswerNone, false},
	} {
		a, known := ParseAnswer(raw)
		if a != want.a || known != want.known {
			t.Errorf("ParseAnswer(%q) = (%q, %v), want (%q, %v)", raw, a, known, want.a, want.known)
		}
	}
}

func TestLogLine(t *testing.T) {
	const tail = ` — sync keeps running; allow it in Watchtower or with "watchtower ai background allow"`
	f := false
	for _, c := range []struct {
		s    State
		want string
	}{
		{Resolve(AnswerAllowed, nil), ""},
		{Resolve(AnswerNone, nil), "background AI: paused (not answered yet)" + tail},
		{Resolve(AnswerPaused, nil), "background AI: paused (paused by you)" + tail},
		{Resolve(AnswerAllowed, &f), "background AI: paused (turned off by your organization)" + tail},
	} {
		if got := LogLine(c.s); got != c.want {
			t.Errorf("LogLine(%+v) = %q, want %q", c.s, got, c.want)
		}
	}
}

// captureLog swaps the package logger for one that records each line.
func captureLog(t *testing.T) *[]string {
	t.Helper()
	var lines []string
	logf = func(format string, args ...any) { lines = append(lines, fmt.Sprintf(format, args...)) }
	return &lines
}

func writeConfig(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestCurrent_UnreadableConfigIsPaused(t *testing.T) {
	resetForTest(t)
	policytest.Set(t, nil)
	lines := captureLog(t)
	SetConfigPath(writeConfig(t, "ai: [background_runs: allowed\n  : :"))
	s := Current()
	if s.Effective != EffectivePaused || s.Reason != ReasonUnanswered {
		t.Fatalf("got %+v, want paused/unanswered", s)
	}
	if len(*lines) != 1 {
		t.Fatalf("logged %d lines, want 1: %q", len(*lines), *lines)
	}
}

func TestCurrent_UnknownValueReadsAbsent(t *testing.T) {
	resetForTest(t)
	policytest.Set(t, nil)
	lines := captureLog(t)
	SetConfigPath(writeConfig(t, "ai: {background_runs: yes}\n"))
	for range 2 {
		s := Current()
		if s.Answer != AnswerNone || s.Effective != EffectivePaused {
			t.Fatalf("got %+v, want no answer, paused", s)
		}
	}
	if len(*lines) != 1 {
		t.Fatalf("logged %d lines after two calls, want 1: %q", len(*lines), *lines)
	}
}

func TestCurrent_ReadsAnswer(t *testing.T) {
	resetForTest(t)
	policytest.Set(t, nil)
	SetConfigPath(writeConfig(t, "ai:\n  provider: claude\n  background_runs: allowed\n"))
	if s := Current(); !s.Allowed() || s.Reason != ReasonOwner {
		t.Fatalf("got %+v, want allowed by the owner", s)
	}
}

func TestCurrent_MissingFileIsUnanswered(t *testing.T) {
	resetForTest(t)
	policytest.Set(t, nil)
	lines := captureLog(t)
	SetConfigPath(filepath.Join(t.TempDir(), "config.yaml"))
	if s := Current(); s.Effective != EffectivePaused || s.Reason != ReasonUnanswered || !s.Prompt {
		t.Fatalf("got %+v, want paused/unanswered with a prompt", s)
	}
	if len(*lines) != 0 {
		t.Fatalf("a missing config is not a failure, logged %q", *lines)
	}
}

func TestCurrent_NoPathIsPaused(t *testing.T) {
	resetForTest(t)
	policytest.Set(t, map[string]any{policy.KeyAllowBackgroundAI: true})
	if s := Current(); s.Allowed() {
		t.Fatalf("no config path must read paused even with a permissive profile, got %+v", s)
	}
}

func TestCurrent_PolicyApplies(t *testing.T) {
	resetForTest(t)
	policytest.Set(t, map[string]any{policy.KeyAllowBackgroundAI: false})
	SetConfigPath(writeConfig(t, "ai: {background_runs: allowed}\n"))
	if s := Current(); s.Allowed() || !s.Locked || s.Answer != AnswerAllowed {
		t.Fatalf("got %+v, want paused and locked by the organization", s)
	}
}

func TestCurrent_RereadsOnlyOnMtimeChange(t *testing.T) {
	resetForTest(t)
	policytest.Set(t, nil)
	parses := 0
	parseHook = func() { parses++ }
	path := writeConfig(t, "ai: {background_runs: paused}\n")
	SetConfigPath(path)
	Current()
	Current()
	if parses != 1 {
		t.Fatalf("two calls parsed %d times, want 1", parses)
	}
	if err := os.WriteFile(path, []byte("ai: {background_runs: allowed}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	later := time.Now().Add(time.Hour)
	if err := os.Chtimes(path, later, later); err != nil {
		t.Fatal(err)
	}
	if s := Current(); !s.Allowed() {
		t.Fatalf("after the rewrite got %+v, want allowed", s)
	}
	if parses != 2 {
		t.Fatalf("after an mtime change parsed %d times, want 2", parses)
	}
}

func pausedReader() State { return Resolve(AnswerNone, nil) }

func TestCheck_NoopOutsideTheDaemon(t *testing.T) {
	resetForTest(t)
	InitProcess("cli", func(string) string { return "" })
	if err := CheckWith(context.Background(), pausedReader); err != nil {
		t.Fatalf("an owner process must not be gated, got %v", err)
	}
}

func TestCheck_OwnerStartedPasses(t *testing.T) {
	resetForTest(t)
	InitProcess("daemon", func(string) string { return "" })
	if err := CheckWith(WithOwnerStarted(context.Background()), pausedReader); err != nil {
		t.Fatalf("an owner-started call must pass, got %v", err)
	}
}

func TestCheck_DaemonBackgroundIsRefused(t *testing.T) {
	resetForTest(t)
	InitProcess("daemon", func(string) string { return "" })
	err := CheckWith(context.Background(), pausedReader)
	if !errors.Is(err, ErrPaused) || err.Error() != "Background AI is paused" {
		t.Fatalf("got %v, want ErrPaused", err)
	}
	allowed := func() State { return Resolve(AnswerAllowed, nil) }
	if err := CheckWith(context.Background(), allowed); err != nil {
		t.Fatalf("allowed: got %v", err)
	}
}

func TestCheck_NilReaderReadsCurrent(t *testing.T) {
	resetForTest(t)
	policytest.Set(t, nil)
	InitProcess("daemon", func(string) string { return "" })
	if err := CheckWith(context.Background(), nil); !errors.Is(err, ErrPaused) {
		t.Fatalf("nil reader with no config path must fail closed, got %v", err)
	}
	if err := Check(context.Background()); !errors.Is(err, ErrPaused) {
		t.Fatalf("Check with no config path must fail closed, got %v", err)
	}
}

func TestOverrideWinsOverConfig(t *testing.T) {
	resetForTest(t)
	SetCurrentOverrideForTest(func() State { return Resolve(AnswerAllowed, nil) })
	if !Current().Allowed() {
		t.Fatal("the test override must answer Current")
	}
	SetCurrentOverrideForTest(nil)
	if Current().Allowed() {
		t.Fatal("clearing the override must restore the config read")
	}
}

// resetForTest clears the package state (config read, process origin, test
// hooks) and restores it when the test ends.
func resetForTest(t *testing.T) {
	t.Helper()
	cur.mu.Lock()
	savedPath, savedOverride, savedInfo, savedAnswer, savedFail := cur.path, cur.override, cur.info, cur.answer, cur.lastFail
	cur.path, cur.override, cur.info, cur.answer, cur.lastFail = "", nil, nil, AnswerNone, ""
	cur.mu.Unlock()
	proc.mu.Lock()
	savedMark, savedRunID, savedLookup := proc.mark, proc.runID, proc.lookup
	proc.mark, proc.runID, proc.lookup = originMark{}, "", nil
	proc.mu.Unlock()
	savedLogf, savedParseHook := logf, parseHook
	t.Cleanup(func() {
		cur.mu.Lock()
		cur.path, cur.override, cur.info, cur.answer, cur.lastFail = savedPath, savedOverride, savedInfo, savedAnswer, savedFail
		cur.mu.Unlock()
		proc.mu.Lock()
		proc.mark, proc.runID, proc.lookup = savedMark, savedRunID, savedLookup
		proc.mu.Unlock()
		logf, parseHook = savedLogf, savedParseHook
	})
}
