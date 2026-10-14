package db

import (
	"testing"
	"time"
)

func TestAutomationRunStatsSince_LastStatusAndWindowTokens(t *testing.T) {
	d := openTestDB(t)
	since := time.Date(2026, 3, 10, 0, 0, 0, 0, time.UTC)
	a := seedRunAutomation(t, d, "digest", 4)
	idle := seedRunAutomation(t, d, "idle", 1)
	for i, started := range []time.Time{since.Add(-time.Hour), since.Add(time.Hour)} {
		tr := []string{TriggerManual, TriggerButton}[i]
		run, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: tr})
		if ok, err := d.ClaimAutomationRun(run, "h", "s", 50000, 5, started); err != nil || !ok {
			t.Fatalf("claim = (%v, %v)", ok, err)
		}
		if err := d.AddAutomationRunUsage(run, RunUsage{InputTokens: int64(100 * (i + 1)), OutputTokens: 10}); err != nil {
			t.Fatal(err)
		}
	}
	// The newest run is still queued: never started, it adds no tokens.
	mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerSchedule})

	stats, err := d.AutomationRunStatsSince(since)
	if err != nil {
		t.Fatal(err)
	}
	if got := stats[a]; got.LastStatus != RunQueued || got.TokensSince != 210 {
		t.Errorf("stats[a] = %+v; want queued, 210 tokens (only the run started after since)", got)
	}
	if _, ok := stats[idle]; ok {
		t.Errorf("an automation without runs is not in the map: %+v", stats[idle])
	}
}
