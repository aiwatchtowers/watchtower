package planusage

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"os"
	"strings"
	"testing"
	"time"

	"watchtower/internal/codex"
	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var updatePlansGoldens = flag.Bool("update-plans", false, "update aggregate v1 synthetic goldens")

func TestPlansAggregate_GoldenWire(t *testing.T) {
	now := time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)
	type scenario struct {
		requested        string
		refresh, enabled bool
		read             func(string) (*PublicStatus, error)
		refreshers       map[string]func(context.Context) error
	}
	unavailable := &PublicStatus{State: "unavailable", Reason: "no_credentials", UpdatedAt: now, LastError: "Plan usage: no_credentials.", Stale: true, Limits: []PublicLimit{}, Breakdown: []BreakdownRow{}}
	cases := map[string]scenario{
		"empty":                          {requested: "all", enabled: true, read: func(string) (*PublicStatus, error) { return nil, nil }},
		"unavailable_is_successful_read": {requested: "claude", enabled: true, read: func(string) (*PublicStatus, error) { return unavailable, nil }},
		"read_failure": {requested: "codex", enabled: true, read: func(string) (*PublicStatus, error) {
			return nil, errors.New("private-path identity-canary@example.com")
		}},
		"disabled_refresh": {requested: "all", refresh: true, read: func(string) (*PublicStatus, error) { return nil, nil }},
		"busy":             {requested: "codex", refresh: true, enabled: true, read: func(string) (*PublicStatus, error) { return nil, nil }, refreshers: map[string]func(context.Context) error{"codex": func(context.Context) error { return &OperationError{Code: "busy"} }}},
		"partial": {requested: "all", refresh: true, enabled: true, read: func(string) (*PublicStatus, error) { return nil, nil }, refreshers: map[string]func(context.Context) error{
			"claude": func(context.Context) error { return nil }, "codex": func(context.Context) error { return &OperationError{Code: "unsupported_auth"} },
		}},
	}
	got := map[string]Envelope{}
	for name, c := range cases {
		got[name] = Collect(context.Background(), c.requested, c.refresh, c.enabled, c.read, c.refreshers)
	}
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	defer d.Close()
	reset := now.Add(time.Hour)
	scope := strings.Repeat("a", 64)
	require.NoError(t, StoreCodexUsage(d, now.Add(-20*time.Minute), testCodexSnapshot(scope, reset, 20)))
	snapshot := testCodexSnapshot(scope, reset, 40)
	allowed := false
	snapshot.OrdinaryUsageAllowed = &allowed
	require.NoError(t, StoreCodexUsage(d, now, snapshot))
	read := func(provider string) (*PublicStatus, error) { return ReadStatus(d, provider, true, now) }
	got["drawable"] = Collect(context.Background(), "codex", false, true, read, nil)
	staleRead := func(provider string) (*PublicStatus, error) {
		return ReadStatus(d, provider, true, now.Add(901*time.Second))
	}
	got["stale"] = Collect(context.Background(), "codex", false, true, staleRead, nil)
	require.NoError(t, StoreCodexUsage(d, now, testCodexSnapshot("", reset, 7)))
	got["unknown_identity"] = Collect(context.Background(), "codex", false, true, read, nil)
	encoded, err := json.MarshalIndent(got, "", "  ")
	require.NoError(t, err)
	const path = "testdata/aggregate_v1.json"
	if *updatePlansGoldens {
		require.NoError(t, os.WriteFile(path, append(encoded, '\n'), 0600))
	}
	want, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.JSONEq(t, string(want), string(encoded))
	for _, canary := range []string{scope, "identity-canary", "private-path", "Scope", "accountId"} {
		assert.NotContains(t, string(encoded), canary)
	}
	drawable := got["drawable"].Providers[0].Status.Limits[0].Projection
	require.True(t, drawable.Drawable)
	require.NotNil(t, drawable.Line)
	require.Equal(t, now, drawable.Line.StartAt)
	require.Equal(t, 40.0, drawable.Line.StartPercent)
	require.Nil(t, got["stale"].Providers[0].Status.Limits[0].Projection.Line)
}

func TestPlansAggregate_ExitPriorityCombined(t *testing.T) {
	for _, tt := range []struct {
		name                      string
		signal                    int
		refresh, enabled, failure bool
		want                      int
	}{
		{"sigint_disabled_storage", 2, true, false, true, 130},
		{"sigterm_disabled_storage", 15, true, false, true, 143},
		{"disabled_storage", 0, true, false, true, 3},
		{"enabled_partial", 0, true, true, true, 1},
		{"all_success", 0, true, true, false, 0},
		{"readonly_disabled_storage", 0, false, false, true, 1},
		{"readonly_disabled_success", 0, false, false, false, 0},
	} {
		t.Run(tt.name, func(t *testing.T) {
			calls := 0
			read := func(string) (*PublicStatus, error) {
				if tt.failure {
					return nil, errors.New("storage failure")
				}
				return nil, nil
			}
			e := Collect(context.Background(), "codex", tt.refresh, tt.enabled, read, map[string]func(context.Context) error{"codex": func(context.Context) error { calls++; return nil }})
			require.Equal(t, tt.want, ExitCode(e, tt.signal))
			if !tt.enabled {
				require.Zero(t, calls)
			}
		})
	}
}

func TestPlansAggregate_ParallelNoFailFast(t *testing.T) {
	started := make(chan string, 2)
	release := make(chan struct{})
	source := func(name string) func(context.Context) error {
		return func(context.Context) error {
			started <- name
			<-release
			if name == "claude" {
				return &OperationError{Code: "network"}
			}
			return nil
		}
	}
	done := make(chan Envelope, 1)
	go func() {
		done <- Collect(context.Background(), "all", true, true, func(string) (*PublicStatus, error) { return nil, nil }, map[string]func(context.Context) error{"claude": source("claude"), "codex": source("codex")})
	}()
	a, b := <-started, <-started
	require.NotEqual(t, a, b)
	close(release)
	e := <-done
	require.Len(t, e.Providers, 2)
	require.Equal(t, "claude", e.Providers[0].Provider)
	require.False(t, e.Providers[0].OK)
	require.True(t, e.Providers[1].OK)
}

func TestPlansAggregate_StoredValidationAndIdentitySuppression(t *testing.T) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	defer d.Close()
	now := at(10, 0)
	reset := now.Add(time.Hour)
	require.NoError(t, StoreCodexUsage(d, now, testCodexSnapshot(strings.Repeat("a", 64), reset, 70)))
	require.NoError(t, StoreCodexFailure(d, now, codex.UsageSnapshot{}, "network"))
	s, err := ReadStatus(d, "codex", true, now)
	require.NoError(t, err)
	require.Empty(t, s.Limits)
	require.False(t, s.HistoryAvailable)
	require.NoError(t, StoreCodexUsage(d, now, testCodexSnapshot("", reset, 4)))
	s, err = ReadStatus(d, "codex", true, now)
	require.NoError(t, err)
	require.Len(t, s.Limits, 1)
	require.Equal(t, 4.0, s.Limits[0].Percent)
	require.False(t, s.HistoryAvailable)
	require.Equal(t, "identity_unknown", *s.Limits[0].Projection.UnavailableReason)
	_, err = d.Exec(`UPDATE codex_plan_usage_status SET plot_json='{"schema_version":99}'`)
	require.NoError(t, err)
	_, err = ReadStatus(d, "codex", true, now)
	require.Error(t, err)
	_, err = d.Exec(`UPDATE codex_plan_usage_status SET plot_json='{}'`)
	require.NoError(t, err)
	_, err = ReadStatus(d, "codex", true, now)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE codex_plan_usage_status SET breakdown_json='[{"key":"x","label":"X"}]'`)
	require.NoError(t, err)
	_, err = ReadStatus(d, "codex", true, now)
	require.Error(t, err, "missing percent must not invent a zero")
	_, err = d.Exec(`UPDATE codex_plan_usage_status SET breakdown_json='[]'`)
	require.NoError(t, err)
	stored, err := d.GetCodexPlanUsageStatus()
	require.NoError(t, err)
	limits, err := DecodeWindowLimits(stored.LimitsJSON)
	require.NoError(t, err)
	shifted := reset.In(time.FixedZone("synthetic-offset", 3600))
	limits[0].ResetsAt = &shifted
	encoded, err := json.Marshal(limits)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE codex_plan_usage_status SET limits_json=?`, string(encoded))
	require.NoError(t, err)
	s, err = ReadStatus(d, "codex", true, now)
	require.NoError(t, err)
	wire, err := json.Marshal(s)
	require.NoError(t, err)
	require.NotContains(t, string(wire), "+01:00", "public timestamps are UTC")
}
