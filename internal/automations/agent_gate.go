package automations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// errAgentRunEnded refuses a call an agent() child makes after its run left
// running (finished, cancelled, interrupted, or gone).
var errAgentRunEnded = errors.New("the automation run has ended")

// GateAgentCall is the per-call gate of a tool an automation's agent() child
// calls (spec §6.5) — the `mcp --surface automation` server's and the
// runtime-B loop's: the run is re-read and must still be running; a dry run
// makes no write; the manifest must admit the call — AllowTool, or for the
// tool behind an outputs-only shortcut (outputs:[target] → create_target,
// which EffectiveAgentTools offers) AllowOutput, the gate output.target
// uses; the list limit is clamped (ClampListLimit). It returns the args to
// dispatch. A denial reads "PermissionDenied: needs <permission>".
func GateAgentCall(ctx context.Context, d *db.DB, m *Manifest, runID int64, t *tools.Tool, args json.RawMessage) (json.RawMessage, error) {
	run, err := d.GetAutomationRun(runID)
	if errors.Is(err, db.ErrAutomationRunNotFound) {
		return nil, errAgentRunEnded
	}
	if err != nil {
		return nil, fmt.Errorf("reading automation run %d: %w", runID, err)
	}
	if run.Status != db.RunRunning {
		return nil, errAgentRunEnded
	}
	if run.Trigger == db.TriggerDryRun && t.Access == tools.AccessWrite {
		return nil, notAvailable(t.Name + " is a write tool; a dry run makes no writes")
	}
	if _, err := m.AllowTool(ctx, d, t, args); err != nil {
		if !m.admitsAsOutput(t) {
			return nil, agentDenial(err)
		}
		if _, err := m.AllowOutput(outputTools[t.Name]); err != nil {
			return nil, agentDenial(err)
		}
	}
	return ClampListLimit(t, args), nil
}

// agentDenial is a manifest denial as the agent sees it: the permission it
// needs, or the reason when no single permission would do.
func agentDenial(err error) error {
	var pd *PermissionDenied
	if !errors.As(err, &pd) {
		return err
	}
	if pd.Needed == "" {
		return &SDKError{Name: ErrNamePermissionDenied, Message: pd.Reason}
	}
	return &SDKError{Name: ErrNamePermissionDenied, Message: "needs " + pd.Needed, Needed: pd.Needed}
}

// CheckAgentResult refuses a tool result an agent() child would receive that
// is over MaxSDKResultBytes, as the SDK refuses a script's (ResultTooLarge,
// never truncated).
func CheckAgentResult(result []byte) error {
	if len(result) > MaxSDKResultBytes {
		return &SDKError{Name: ErrNameResultTooLarge,
			Message: fmt.Sprintf("the result is %d bytes; the limit is %d", len(result), MaxSDKResultBytes)}
	}
	return nil
}
