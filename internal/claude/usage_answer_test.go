package claude

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func loadUsageFixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

type windowID struct{ Key, Label, Group string }

func windowIDs(ws []UsageWindow) []windowID {
	out := make([]windowID, 0, len(ws))
	for _, w := range ws {
		out = append(out, windowID{w.Key, w.Label, w.Group})
	}
	return out
}

func mustParseUsage(t *testing.T, payload []byte) UsageSnapshot {
	t.Helper()
	snap, available, limitsNull, err := parseClaudeUsage(payload)
	if err != nil || !available || limitsNull {
		t.Fatalf("parseClaudeUsage: available=%v limitsNull=%v err=%v", available, limitsNull, err)
	}
	return snap
}

// The keys, labels and groups are the ones stored before the reader existed,
// so history, forecasts and notification keys carry across the upgrade.
func TestParseClaudeUsage_KeysMatchLegacy(t *testing.T) {
	snap := mustParseUsage(t, loadUsageFixture(t, "get_usage_full.json"))
	want := []windowID{
		{"session", "5-hour", "session"},
		{"weekly_all", "Weekly", "weekly"},
		{"weekly_scoped:fable", "Weekly · Fable", "weekly"},
	}
	if got := windowIDs(snap.Windows); !reflect.DeepEqual(got, want) {
		t.Fatalf("windows = %v, want %v", got, want)
	}
	if snap.Plan != "max" {
		t.Errorf("plan = %q, want max", snap.Plan)
	}
	if p := snap.Windows[0].Percent; p != 12.5 {
		t.Errorf("session percent = %v, want 12.5", p)
	}
	if p := snap.Windows[1].Percent; p != 40 {
		t.Errorf("weekly percent = %v, want 40", p)
	}
	if p := snap.Windows[2].Percent; p != 100 {
		t.Errorf("Fable percent = %v, want clamped 100", p)
	}
	wantReset := time.Date(2026, 11, 18, 15, 30, 0, 123456789, time.UTC)
	if r := snap.Windows[0].ResetsAt; r == nil || !r.Equal(wantReset) {
		t.Errorf("session reset = %v, want %v", r, wantReset)
	}

	legacy := mustParseUsage(t, loadUsageFixture(t, "get_usage_legacy_windows.json"))
	wantLegacy := []windowID{
		{"session", "5-hour", "session"},
		{"weekly_all", "Weekly", "weekly"},
		{"weekly_scoped:opus", "Weekly · Opus", "weekly"},
	}
	if got := windowIDs(legacy.Windows); !reflect.DeepEqual(got, wantLegacy) {
		t.Fatalf("legacy windows = %v, want %v", got, wantLegacy)
	}
}

// A null window or a null utilization is absent, never 0 %; a null reset is
// a window that has not started.
func TestParseClaudeUsage_NullWindowIsAbsent(t *testing.T) {
	snap := mustParseUsage(t, loadUsageFixture(t, "get_usage_idle.json"))
	if got, want := windowIDs(snap.Windows), []windowID{{"weekly_scoped:opus", "Weekly · Opus", "weekly"}}; !reflect.DeepEqual(got, want) {
		t.Fatalf("windows = %v, want %v", got, want)
	}
	if snap.Windows[0].ResetsAt != nil {
		t.Errorf("ResetsAt = %v, want nil", snap.Windows[0].ResetsAt)
	}
	if snap.Windows[0].Percent != 3 {
		t.Errorf("percent = %v, want 3", snap.Windows[0].Percent)
	}
}

func TestParseClaudeUsage_ModelScopedAbsent(t *testing.T) {
	payload := []byte(`{"subscription_type":"max","rate_limits_available":true,"rate_limits":{` +
		`"five_hour":{"utilization":1,"resets_at":null},"seven_day":{"utilization":2,"resets_at":null}}}`)
	snap := mustParseUsage(t, payload)
	want := []windowID{{"session", "5-hour", "session"}, {"weekly_all", "Weekly", "weekly"}}
	if got := windowIDs(snap.Windows); !reflect.DeepEqual(got, want) {
		t.Fatalf("windows = %v, want %v", got, want)
	}
}

func TestParseClaudeUsage_ModelScopedWinsOverOpus(t *testing.T) {
	// The full fixture carries both model_scoped and seven_day_opus.
	snap := mustParseUsage(t, loadUsageFixture(t, "get_usage_full.json"))
	for _, w := range snap.Windows {
		if w.Key == "weekly_scoped:opus" || w.Key == "weekly_scoped:sonnet" {
			t.Fatalf("legacy scoped window %q present beside model_scoped", w.Key)
		}
	}
	// An empty model_scoped list still means the endpoint answered: no
	// fallback to the opus window.
	payload := []byte(`{"subscription_type":"max","rate_limits_available":true,"rate_limits":{` +
		`"five_hour":{"utilization":1,"resets_at":null},"seven_day_opus":{"utilization":2,"resets_at":null},"model_scoped":[]}}`)
	snap = mustParseUsage(t, payload)
	if got, want := windowIDs(snap.Windows), []windowID{{"session", "5-hour", "session"}}; !reflect.DeepEqual(got, want) {
		t.Fatalf("windows = %v, want %v", got, want)
	}
}

func TestParseClaudeUsage_BreakdownOptional(t *testing.T) {
	snap := mustParseUsage(t, loadUsageFixture(t, "get_usage_full.json"))
	want := []BreakdownRow{{"claude_code", "Claude Code", 80}, {"claude_ai", "Claude.ai", 20}}
	if !reflect.DeepEqual(snap.Breakdown, want) {
		t.Fatalf("breakdown = %v, want %v", snap.Breakdown, want)
	}
	snap = mustParseUsage(t, loadUsageFixture(t, "get_usage_no_breakdown.json"))
	if snap.Breakdown != nil {
		t.Fatalf("breakdown = %v, want nil", snap.Breakdown)
	}
}

func TestParseClaudeUsage_Malformed(t *testing.T) {
	for name, payload := range map[string]string{
		"not json":           `not json`,
		"rate_limits string": `{"rate_limits_available":true,"rate_limits":"x"}`,
		"utilization string": `{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":"12","resets_at":null}}}`,
		"available missing":  `{"subscription_type":"max","rate_limits":null}`,
	} {
		if _, _, _, err := parseClaudeUsage([]byte(payload)); err == nil {
			t.Errorf("%s: no error", name)
		}
	}

	snap, available, _, err := parseClaudeUsage([]byte(`{"subscription_type":null,"rate_limits_available":true,` +
		`"rate_limits":{"five_hour":{"utilization":1,"resets_at":null}}}`))
	if err != nil || !available || snap.Plan != "" {
		t.Errorf("null subscription_type: plan=%q available=%v err=%v", snap.Plan, available, err)
	}

	_, available, _, err = parseClaudeUsage([]byte(`{"subscription_type":null,"rate_limits_available":false,"rate_limits":null}`))
	if err != nil || available {
		t.Errorf("rate_limits_available:false: available=%v err=%v", available, err)
	}

	_, available, limitsNull, err := parseClaudeUsage([]byte(`{"subscription_type":"max","rate_limits_available":true,"rate_limits":null}`))
	if err != nil || !available || !limitsNull {
		t.Errorf("rate_limits:null: available=%v limitsNull=%v err=%v", available, limitsNull, err)
	}
}

// A reshaped pass-through breakdown costs only the breakdown, never the
// windows.
func TestParseClaudeUsage_MalformedBreakdownKeepsWindows(t *testing.T) {
	for name, bd := range map[string]string{
		"rows string":    `{"rows":"x"}`,
		"percent string": `{"rows":[{"key":"a","display_name":"A","percent":"80"}]}`,
		"array":          `[1,2]`,
		"null":           `null`,
	} {
		payload := []byte(`{"subscription_type":"max","rate_limits_available":true,"rate_limits":{` +
			`"five_hour":{"utilization":1,"resets_at":null},"seven_day_breakdown":` + bd + `}}`)
		snap := mustParseUsage(t, payload)
		if len(snap.Windows) != 1 || snap.Breakdown != nil {
			t.Errorf("%s: windows=%v breakdown=%v", name, snap.Windows, snap.Breakdown)
		}
	}
}
