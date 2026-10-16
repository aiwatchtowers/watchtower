package db

import (
	"database/sql"
	"fmt"
	"slices"
	"strings"
)

// agentReportMinParserVersion is the first agentlog parser version that stores
// owner-turn triggers and Agent-call links: a floor, not the current version
// (db cannot import agentlog).
const agentReportMinParserVersion = 2

// AgentReportEvent is the slice of one agent_log_events row the #298 report reads.
type AgentReportEvent struct {
	SessionUUID, Kind, TS, AgentID, Name, Target, Trigger, Outcome, SpawnedAgentID, Model string
	Background                                                                            bool
	DurationMS                                                                            *int64
	CostUSD                                                                               float64
	CostEstimated                                                                         bool
	InputTokens, OutputTokens, CacheReadTokens, CacheWrite5mTokens, CacheWrite1hTokens    int64
	SrcPath                                                                               string
	SrcOffset                                                                             int64
}

// AgentReportSession is one session of the report window.
type AgentReportSession struct {
	SessionUUID, StartedAt, EndedAt, Model, GitBranch string
	OldFormat                                         bool // every source file missing_at with parser_version < 2
}

// AgentReportSessions lists a workbench's sessions that started or ended at or
// after since, oldest first.
func (db *DB) AgentReportSessions(projectID int64, since string) ([]AgentReportSession, error) {
	out := []AgentReportSession{}
	err := db.agentLogRows(`WITH files AS (
			SELECT s.session_uuid, f.missing_at, f.parser_version
			FROM agent_log_sessions s JOIN agent_log_files f ON f.path = s.source_path
			WHERE s.project_id = ?
			UNION
			SELECT e.session_uuid, f.missing_at, f.parser_version
			FROM agent_log_events e JOIN agent_log_sessions s ON s.session_uuid = e.session_uuid
			JOIN agent_log_files f ON f.path = e.src_path
			WHERE s.project_id = ?)
		SELECT s.session_uuid, s.started_at, s.ended_at, s.model, s.git_branch,
			EXISTS (SELECT 1 FROM files WHERE files.session_uuid = s.session_uuid)
			AND NOT EXISTS (SELECT 1 FROM files WHERE files.session_uuid = s.session_uuid
				AND (files.missing_at IS NULL OR files.parser_version >= ?))
		FROM agent_log_sessions s
		WHERE s.project_id = ? AND (s.started_at >= ? OR s.ended_at >= ?)
		ORDER BY s.started_at, s.session_uuid`,
		[]any{projectID, projectID, agentReportMinParserVersion, projectID, since, since},
		func(r *sql.Rows) error {
			var s AgentReportSession
			if err := r.Scan(&s.SessionUUID, &s.StartedAt, &s.EndedAt, &s.Model, &s.GitBranch, &s.OldFormat); err != nil {
				return err
			}
			out = append(out, s)
			return nil
		})
	if err != nil {
		return nil, fmt.Errorf("agent report sessions: %w", err)
	}
	return out, nil
}

// agentReportChunk bounds the IN list of one events query.
const agentReportChunk = 500

// AgentReportEvents returns the events of the given sessions, ordered by
// session, ts, src_path, src_offset.
func (db *DB) AgentReportEvents(sessionUUIDs []string) ([]AgentReportEvent, error) {
	out := []AgentReportEvent{}
	ids := slices.Clone(sessionUUIDs)
	slices.Sort(ids) // chunks keep the overall order only when the ids are sorted
	for len(ids) > 0 {
		n := min(len(ids), agentReportChunk)
		chunk := ids[:n]
		ids = ids[n:]
		args := make([]any, len(chunk))
		for i, id := range chunk {
			args[i] = id
		}
		err := db.agentLogRows(`SELECT session_uuid, kind, ts, agent_id, name, target, trigger, outcome,
			spawned_agent_id, background, duration_ms, cost_usd, cost_estimated,
			input_tokens, output_tokens, cache_read_tokens, cache_write_5m_tokens, cache_write_1h_tokens,
			src_path, src_offset
			FROM agent_log_events WHERE session_uuid IN (?`+strings.Repeat(",?", len(chunk)-1)+`)
			ORDER BY session_uuid, ts, src_path, src_offset`, args,
			func(r *sql.Rows) error {
				var e AgentReportEvent
				var dur sql.NullInt64
				if err := r.Scan(&e.SessionUUID, &e.Kind, &e.TS, &e.AgentID, &e.Name, &e.Target, &e.Trigger, &e.Outcome,
					&e.SpawnedAgentID, &e.Background, &dur, &e.CostUSD, &e.CostEstimated,
					&e.InputTokens, &e.OutputTokens, &e.CacheReadTokens, &e.CacheWrite5mTokens, &e.CacheWrite1hTokens,
					&e.SrcPath, &e.SrcOffset); err != nil {
					return err
				}
				if dur.Valid {
					e.DurationMS = &dur.Int64
				}
				if e.Kind == "api_call" {
					e.Model = e.Name
				}
				out = append(out, e)
				return nil
			})
		if err != nil {
			return nil, fmt.Errorf("agent report events: %w", err)
		}
	}
	return out, nil
}

// StatusChange is one target_status_history row: the status entered and when.
type StatusChange struct{ To, At string }

// AgentReportTarget is a workbench board target with its status history,
// oldest change first.
type AgentReportTarget struct {
	ID       int64
	ParentID *int64
	Text     string
	Status   string
	History  []StatusChange
}

// AgentReportTargets lists a workbench's targets by id with their status history.
func (db *DB) AgentReportTargets(projectID int64) ([]AgentReportTarget, error) {
	out := []AgentReportTarget{}
	byID := map[int64]int{}
	err := db.agentLogRows(`SELECT id, parent_id, text, status FROM targets WHERE project_id = ? ORDER BY id`,
		[]any{projectID}, func(r *sql.Rows) error {
			var t AgentReportTarget
			var parent sql.NullInt64
			if err := r.Scan(&t.ID, &parent, &t.Text, &t.Status); err != nil {
				return err
			}
			if parent.Valid {
				t.ParentID = &parent.Int64
			}
			byID[t.ID] = len(out)
			out = append(out, t)
			return nil
		})
	if err != nil {
		return nil, fmt.Errorf("agent report targets: %w", err)
	}
	err = db.agentLogRows(`SELECT h.target_id, h.to_status, h.changed_at
		FROM target_status_history h JOIN targets t ON t.id = h.target_id
		WHERE t.project_id = ? ORDER BY h.target_id, h.changed_at, h.id`,
		[]any{projectID}, func(r *sql.Rows) error {
			var id int64
			var c StatusChange
			if err := r.Scan(&id, &c.To, &c.At); err != nil {
				return err
			}
			if i, ok := byID[id]; ok {
				out[i].History = append(out[i].History, c)
			}
			return nil
		})
	if err != nil {
		return nil, fmt.Errorf("agent report target history: %w", err)
	}
	return out, nil
}
