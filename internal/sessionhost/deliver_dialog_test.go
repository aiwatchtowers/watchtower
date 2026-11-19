package sessionhost

import (
	"context"
	"syscall"
	"testing"
)

// A line that holds on prompt text holds on a permission dialog too, under
// the lock that decides and pastes: nothing is written, however the dialog
// opened after the caller's own state read (PROJ-16, PROJ-23). Once the
// dialog is gone the line goes as usual.
func TestDeliverHoldsAtAPermissionDialogBeforeAnyByte(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	cl := st.hub()
	st.hint(true)
	r := st.req("x")
	r.HoldIfPromptText = true
	wantOutcome(t, st.deliver(cl, r, noCheck(t)), OutcomeHeld, HeldDialog)
	wantBytes(t, st.written(), nil, "nothing typed into the dialog")

	st.hint(false)
	wantOutcome(t, st.deliver(cl, r, nil), OutcomeSubmitted, "")
	wantBytes(t, st.written(), cat(paste("x"), []byte{0x0D}), "after the dialog closed")
}

// A run that ends during the pause, after the paste, answers no_session
// with LostAfterPaste: the line may have reached the agent, unlike a
// no_session before any byte (no reason).
func TestDeliverRunLostAfterThePasteSaysSo(t *testing.T) {
	var hook pauseHook
	st := newStub(t, hook.opts(), "claude", rawEchoAgent)
	hook.during = func() {
		_ = syscall.Kill(-st.info.Pid, syscall.SIGKILL)
		<-st.exited
	}
	wantOutcome(t, st.deliver(st.hub(), st.req("x"), func(context.Context) DeliverCheckReplyMsg {
		return okCheck(context.Background())
	}), OutcomeNoSession, LostAfterPaste)

	gone := st.req("y")
	gone.Launch++
	out := st.deliver(st.hub(), gone, noCheck(t))
	if out.Outcome != OutcomeNoSession || out.Reason != "" {
		t.Fatalf("a line for no running launch = %+v, want no_session without a reason", out)
	}
}
