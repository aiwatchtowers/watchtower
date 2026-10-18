package agentlogdb

import (
	"database/sql"
	"fmt"
	"slices"
	"strings"
)

// agentReportMinParserVersion is the first agentlog parser version that stores
// owner-turn triggers and Agent-call links: a floor, not the current version
// (agentlogdb cannot import agentlog).
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
	OldFormat                                         bool // some source file has parser_version < 2 (a present one clears on its next scan)
}

// AgentReportSessions lists a workbench's sessions that started or ended at or
// after since, oldest first.
func (d *DB) AgentReportSessions(projectID int64, since string) ([]AgentReportSession, error) {
	out := []AgentReportSession{}
	err := d.agentLogRows(`WITH files AS (
			SELECT s.session_uuid, f.parser_version
			FROM agent_log_sessions s JOIN agent_log_files f ON f.path = s.source_path
			WHERE s.project_id = ?
			UNION
			SELECT e.session_uuid, f.parser_version
			FROM agent_log_events e JOIN agent_log_sessions s ON s.session_uuid = e.session_uuid
			JOIN agent_log_files f ON f.path = e.src_path
			WHERE s.project_id = ?)
		SELECT s.session_uuid, s.started_at, s.ended_at, s.model, s.git_branch,
			EXISTS (SELECT 1 FROM files WHERE files.session_uuid = s.session_uuid
				AND files.parser_version < ?)
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
// session, ts, src_path, src_offset, key.
func (d *DB) AgentReportEvents(sessionUUIDs []string) ([]AgentReportEvent, error) {
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
		err := d.agentLogRows(`SELECT session_uuid, kind, ts, agent_id, name, target, trigger, outcome,
			spawned_agent_id, background, duration_ms, cost_usd, cost_estimated,
			input_tokens, output_tokens, cache_read_tokens, cache_write_5m_tokens, cache_write_1h_tokens,
			src_path, src_offset
			FROM agent_log_events WHERE session_uuid IN (?`+strings.Repeat(",?", len(chunk)-1)+`)
			ORDER BY session_uuid, ts, src_path, src_offset, key`, args,
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
