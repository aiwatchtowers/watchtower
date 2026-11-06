package cmd

import (
	"errors"
	"time"

	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/logredact"
	"watchtower/internal/sessionfeed"
	"watchtower/internal/sessionhost"
)

// codexWatchBusy is how long a watch's statement waits for another
// process's write lock: the watch ticks every 2 s, so a busy tick is
// simply the next one's work.
const codexWatchBusy = 2 * time.Second

// openCodexWatchStore opens the database a hosted codex launch names for
// its rollout watch (spec 2026-11-05 §3.5, decision C): the existing file
// only, no migration (the app migrated it before the launch; a host binary
// older or newer than the schema must never migrate it), and refused when
// the file has no watch columns yet. The host logs its error, so the error
// carries no path (FILES-01): the open's own, which names the file, is a
// fingerprint.
func openCodexWatchStore(dbPath string) (sessionhost.CodexWatchStore, error) {
	d, err := db.OpenExistingRW(dbPath, codexWatchBusy)
	if err != nil {
		return nil, logredact.Errorf("opening the database: %s", logredact.Text(err.Error()))
	}
	ok, err := d.HasColumns("terminal_sessions", "agent_watch_issue", "agent_watch_issue_at")
	if err != nil {
		_ = d.Close()
		return nil, logredact.Errorf("reading the watch columns: %s", logredact.Text(err.Error()))
	}
	if !ok {
		_ = d.Close()
		return nil, errors.New("the database has no watch columns yet (migration 00173)")
	}
	return &sessionhost.DBWatchStore{DB: d, Record: recordCodexPull}, nil
}

// recordCodexPull writes a codex turn the rollout pull read (board #959,
// ask #499 option A) through the hooks' own path: a failed turn is the
// StopFailure's write (`waiting` with agent_failed_at and the
// codex_error_info), an aborted one the Interrupt's plain `waiting`, both
// only over `working` and stamped with the rollout line's time, so the
// session host's watch and the app's bridge reporting the same turn write
// once, and a prompt that started a newer turn wins.
func recordCodexPull(database *db.DB, row db.CodexWatchRow, turn sessionfeed.CodexTurn) error {
	if turn.At.IsZero() || (!turn.Failed && !turn.Aborted) {
		return nil
	}
	var failure *db.AgentFailure
	if turn.Failed {
		failure = &db.AgentFailure{Error: briefClip(asks.OneLine(turn.Error), agentErrorRunes)}
	}
	return recordAgentState(database, row.ID, row.WorkbenchID, row.SessionID, agentStateWaiting,
		agentStateWorking, failure, false, turn.At, hookTurn{})
}
