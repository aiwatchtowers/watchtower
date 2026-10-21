package automations

import (
	"testing"

	"watchtower/internal/db"
)

// TestAuto08_ReplayLogCapCountsTheStoredLog: the per-run log cap
// (MaxReplayLogBytes) counts what the first daemon life recorded, so a
// resumed run cannot grow its log past the cap again from zero.
func TestAuto08_ReplayLogCapCountsTheStoredLog(t *testing.T) {
	prev := MaxReplayLogBytes
	MaxReplayLogBytes = 20
	t.Cleanup(func() { MaxReplayLogBytes = prev })
	stored := `"0123456789"` // 12 bytes + the clock's 2 = 14 recorded before the restart
	j := NewMemoryJournal()
	j.appendStored(db.AutomationRunStep{Seq: 1, Kind: StepKindLLM, Status: StepOK},
		&db.AutomationRunReplay{Seq: 1, Kind: StepKindLLM, ClockJSON: "[]", ResultJSON: &stored})
	step := j.Begin(StepKindLLM, "light", nil)
	step.record(argsHash(nil), "[]", true)
	step.recordOutcome(encodedResult(`"done"`), nil) // 8 bytes: alone under the cap, 22 with the stored log
	if !j.replayOff {
		t.Fatal("the log passed MaxReplayLogBytes across the restart without making the run not resumable")
	}
}
