package inboxfeed

import (
	"errors"
	"testing"

	"watchtower/internal/tools"
	"watchtower/internal/tower/api"
)

// RetryAction and DismissAction are the one retry and dismiss rule of an
// approval row, shared by inbox.act and the hub's chat_action_answer (mobile
// Inbox spec §12.9).

func refusalCode(t *testing.T, err error) api.RefusalCode {
	t.Helper()
	var r *ActionRefusal
	if !errors.As(err, &r) {
		t.Fatalf("err %v, want an ActionRefusal", err)
	}
	return r.Code
}

func TestRetryAction_FailedRowIsReadyToRun(t *testing.T) {
	d, _, reg := approvalRig(t, nil)
	if _, err := d.Exec(`UPDATE agent_actions SET status = 'failed', error = 'boom' WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	row, res, run, err := RetryAction(d, reg, 1, actNow)
	if err != nil || !run || row == nil || row.ID != 1 || res.Already {
		t.Fatalf("row %v res %+v run %v err %v", row, res, run, err)
	}
	if actionStatusOf(t, d, 1) != "failed" {
		t.Fatal("RetryAction ran the row itself")
	}
}

func TestRetryAction_AppliedIsAlreadyAndPendingIsChanged(t *testing.T) {
	d, _, reg := approvalRig(t, nil)
	if _, _, _, err := RetryAction(d, reg, 1, actNow); refusalCode(t, err) != api.CodeChanged {
		t.Fatal("a pending row was retried")
	}
	if _, err := d.Exec(`UPDATE agent_actions SET status = 'applied' WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	_, res, run, err := RetryAction(d, reg, 1, actNow)
	if err != nil || run || !res.Already || res.Status != statusApplied {
		t.Fatalf("res %+v run %v err %v", res, run, err)
	}
	if _, _, _, err := RetryAction(d, reg, 42, actNow); refusalCode(t, err) != api.CodeNotFound {
		t.Fatal("a missing row was not not_found")
	}
}

func TestRetryAction_SessionCallIsUnsupported(t *testing.T) {
	d, _, reg := approvalRig(t, nil)
	if err := reg.Register(tools.NewClaudeAIConnectorCall()); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`UPDATE agent_actions SET tool = 'claude_ai_connector_call', status = 'failed' WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := RetryAction(d, reg, 1, actNow); refusalCode(t, err) != api.CodeUnsupported {
		t.Fatal("a session call was retried")
	}
}

func TestDismissAction_OnlyAnUnknownOutcomeAndTwiceIsAlready(t *testing.T) {
	d, _, reg := approvalRig(t, nil)
	if err := reg.Register(tools.NewClaudeAIConnectorCall()); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`UPDATE agent_actions SET status = 'failed', error = 'boom' WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	if _, err := DismissAction(d, reg, 1); refusalCode(t, err) != api.CodeChanged {
		t.Fatal("an ordinary failed row was dismissed")
	}
	if _, err := d.Exec(`UPDATE agent_actions SET tool = 'claude_ai_connector_call',
		error = 'session ended while the call ran; outcome unknown' WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	res, err := DismissAction(d, reg, 1)
	if err != nil || res.Already {
		t.Fatalf("first dismiss %+v %v", res, err)
	}
	var first string
	if err := d.QueryRow(`SELECT dismissed_at FROM agent_actions WHERE id = 1`).Scan(&first); err != nil || first == "" {
		t.Fatalf("not dismissed: %q %v", first, err)
	}
	res, err = DismissAction(d, reg, 1)
	if err != nil || !res.Already {
		t.Fatalf("second dismiss %+v %v", res, err)
	}
	if _, err := DismissAction(d, reg, 42); refusalCode(t, err) != api.CodeNotFound {
		t.Fatal("a missing row was not not_found")
	}
}
