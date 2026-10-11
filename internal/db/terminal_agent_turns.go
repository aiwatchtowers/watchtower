package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"time"
)

// maxAgentTurns caps the turns one run keeps: a run that launches more
// subagents than this loses its oldest closed turns first, which only lets a
// long-finished subagent that is somehow still listed count again.
const maxAgentTurns = 256

// AgentTurn is one subagent's or teammate's last SubagentStart (Start) and
// SubagentStop (Stop) stamps, agentStateAtLayout; "" when none was seen.
type AgentTurn struct {
	Start string `json:"start,omitempty"`
	Stop  string `json:"stop,omitempty"`
}

// AgentTurns is terminal_sessions.agent_turns (board #543): the turns of the
// run's subagents and teammates, keyed by the hooks' agent_id.
type AgentTurns map[string]AgentTurn

// Open says agentID is inside a turn: its last SubagentStart is later than
// its last SubagentStop.
func (t AgentTurns) Open(agentID string) bool {
	turn, ok := t[agentID]
	return ok && turn.Start != "" && turn.Start > turn.Stop
}

// Closed says agentID's last turn ended: a SubagentStop not earlier than its
// last SubagentStart.
func (t AgentTurns) Closed(agentID string) bool {
	turn, ok := t[agentID]
	return ok && turn.Stop != "" && turn.Stop >= turn.Start
}

// decodeAgentTurns reads a stored agent_turns value; NULL or a value that
// does not decode reads as no turns (the next write replaces it).
func decodeAgentTurns(raw sql.NullString) AgentTurns {
	turns := AgentTurns{}
	if raw.Valid {
		if json.Unmarshal([]byte(raw.String), &turns) != nil || turns == nil {
			return AgentTurns{}
		}
	}
	return turns
}

// record moves agentID's start (or stop) stamp forward to stamp; an earlier
// stamp, from a hook that landed late, changes nothing. It reports whether
// the map changed.
func (t AgentTurns) record(agentID string, start bool, stamp string) bool {
	turn := t[agentID]
	field := &turn.Stop
	if start {
		field = &turn.Start
	}
	if *field >= stamp {
		return false
	}
	*field = stamp
	t[agentID] = turn
	t.trim(agentID)
	return true
}

// trim drops turns beyond maxAgentTurns, never keep (the turn just
// recorded): closed ones first, oldest last stamp first.
func (t AgentTurns) trim(keep string) {
	if len(t) <= maxAgentTurns {
		return
	}
	ids := make([]string, 0, len(t))
	for id := range t {
		if id != keep {
			ids = append(ids, id)
		}
	}
	last := func(id string) string { return max(t[id].Start, t[id].Stop) }
	sort.Slice(ids, func(i, j int) bool {
		if ci, cj := t.Closed(ids[i]), t.Closed(ids[j]); ci != cj {
			return ci
		}
		return last(ids[i]) < last(ids[j])
	})
	for _, id := range ids[:len(t)-maxAgentTurns] { // len(ids) == len(t)-1 >= that
		delete(t, id)
	}
}

// RecordTerminalAgentTurn records that subagent or teammate agentID started
// (start) or ended a turn at at, reported by a hook of conversation
// sessionID on workbench workbenchID's claude row id (board #543). Each stamp
// only moves forward, so two async hooks landing out of order never reopen a
// turn. One write transaction, the row guards of SetTerminalAgentState; no
// other column changes. It returns the row's turns after the write (also when
// the stamp was not newer), or nil when a guard held it back.
func (db *DB) RecordTerminalAgentTurn(id, workbenchID int64, sessionID, agentID string, start bool,
	at time.Time) (AgentTurns, error) {
	if agentID == "" {
		return nil, nil
	}
	tx, err := db.Begin()
	if err != nil {
		return nil, fmt.Errorf("recording terminal session %d agent turn: %w", id, err)
	}
	defer func() { _ = tx.Rollback() }()
	var raw sql.NullString
	err = tx.QueryRow(`SELECT agent_turns FROM terminal_sessions
		WHERE id = ? AND project_id = ? AND kind = 'claude' AND claude_session_id = ?`,
		id, workbenchID, sessionID).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading terminal session %d agent turns: %w", id, err)
	}
	turns := decodeAgentTurns(raw)
	if !turns.record(agentID, start, AgentStateStamp(at)) {
		return turns, nil
	}
	body, err := json.Marshal(turns)
	if err != nil {
		return nil, fmt.Errorf("encoding terminal session %d agent turns: %w", id, err)
	}
	if _, err := tx.Exec(`UPDATE terminal_sessions SET agent_turns = ? WHERE id = ?`, string(body), id); err != nil {
		return nil, fmt.Errorf("recording terminal session %d agent turn: %w", id, err)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("recording terminal session %d agent turn: %w", id, err)
	}
	return turns, nil
}
