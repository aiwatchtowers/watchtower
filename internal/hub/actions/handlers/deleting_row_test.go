package handlers

import (
	"testing"
	"time"

	"watchtower/internal/hub/wire"
)

// A session being deleted (delete_requested_at, #1716) is missing for the
// phone's actions: spec §4 "Readers of a row being deleted".

const deletingStamp = "2026-11-10T12:00:00Z"

func TestSessionInput_DeletingRowRefused(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "working")
	le.exec(`UPDATE terminal_sessions SET delete_requested_at = ? WHERE id = ?`, deletingStamp, sid)

	out := le.send(le.h, le.input(sid, "Hello"))

	wantOutcome(t, out, wire.StatusFailed, reasonNotFound)
	if out.Message != sessionGoneMessage {
		t.Fatalf("message = %q, want %q", out.Message, sessionGoneMessage)
	}
	wantPastes(t, le)
}

func TestSessionInterrupt_DeletingRowRefused(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	p.setState(sid, "working")
	p.exec(`UPDATE terminal_sessions SET delete_requested_at = ? WHERE id = ?`, deletingStamp, sid)

	got := p.interrupt(sid, time.Second)
	wantOutcome(t, got, wire.StatusFailed, reasonNotFound)
	wantMessage(t, got, sessionGoneMessage)
	if got := p.esc.interrupts(); len(got) != 0 {
		t.Fatalf("interrupts = %v, want none", got)
	}
}
