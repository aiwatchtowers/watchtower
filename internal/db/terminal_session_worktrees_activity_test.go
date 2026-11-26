package db

import (
	"context"
	"testing"
)

func TestWorktreeLastSeen_NewestOfAnySession(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	a := newAgentStateRow(t, d, wb, "claude", agentStateUUID)
	b := newAgentStateRow(t, d, wb, "claude", "22222222-2222-2222-2222-222222222222")
	const root, first, later = "/tmp/example/wt", "2026-10-12T12:00:00.000Z", "2026-10-13T09:00:00.000Z"
	if _, ok, err := d.WorktreeLastSeen(ctx, root); err != nil || ok {
		t.Fatalf("no row = %v, %v; want none", ok, err)
	}
	if _, err := d.RecordSessionWorktree(ctx, nil, a, root, "", first); err != nil {
		t.Fatal(err)
	}
	if _, err := d.RecordSessionWorktree(ctx, nil, b, root, "", first); err != nil {
		t.Fatal(err)
	}
	if _, err := d.TouchSessionWorktree(ctx, b, root, "", later); err != nil {
		t.Fatal(err)
	}
	got, ok, err := d.WorktreeLastSeen(ctx, root)
	if err != nil || !ok || got.UTC().Format(agentStateAtLayout) != later {
		t.Fatalf("WorktreeLastSeen = %v, %v, %v; want %s", got, ok, err, later)
	}
	if _, ok, err := d.WorktreeLastSeen(ctx, "/tmp/example/other"); err != nil || ok {
		t.Fatalf("another root = %v, %v; want none", ok, err)
	}
}

func TestWorktreeLastSeen_UnparsableStampIsAnError(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	id := newAgentStateRow(t, d, newTestWorkbench(t, d), "claude", agentStateUUID)
	const root = "/tmp/example/wt"
	if _, err := d.RecordSessionWorktree(ctx, nil, id, root, "", ledgerAt); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`UPDATE terminal_session_worktrees SET last_at = 'garbage' WHERE root = ?`, root); err != nil {
		t.Fatal(err)
	}
	if _, _, err := d.WorktreeLastSeen(ctx, root); err == nil {
		t.Fatal("an unparsable stamp read as a time; want an error (fail closed)")
	}
}

func TestWorktreeLastSeen_MalformedRowBelowAValidOneIsAnError(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	a := newAgentStateRow(t, d, wb, "claude", agentStateUUID)
	b := newAgentStateRow(t, d, wb, "claude", "33333333-3333-3333-3333-333333333333")
	const root = "/tmp/example/wt"
	for _, id := range []int64{a, b} {
		if _, err := d.RecordSessionWorktree(ctx, nil, id, root, "", ledgerAt); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := d.Exec(`UPDATE terminal_session_worktrees SET last_at = '' WHERE session_id = ?`, b); err != nil {
		t.Fatal(err)
	}
	if _, _, err := d.WorktreeLastSeen(ctx, root); err == nil {
		t.Fatal("a malformed stamp that sorts below a valid one was discarded; want an error")
	}
}
