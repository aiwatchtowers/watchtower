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

// agentReportFactsParserVersion is the first parser version that stores the v2
// facts (result sizes, thinking tokens, context parts, skill listing, sub-agent
// meta); rows below it are "not measured".
const agentReportFactsParserVersion = 3

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
	ErrorClass                                                                            string
	ResultBytes                                                                           *int64 // nil = not measured
	ThinkingTokens                                                                        int64
	PreTokens, PostTokens                                                                 *int64 // compaction context size before and after; nil = not measured
	Skill                                                                                 string // api_call/tool: the skill it ran under (attributionSkill)
}

// AgentReportSession is one session of the report window.
type AgentReportSession struct {
	SessionUUID, StartedAt, EndedAt, Model, GitBranch string
	OldFormat                                         bool // some source file has parser_version < 2 (a present one clears on its next scan)
	Facts                                             bool // every source file has parser_version >= 3, so the v2 facts were measured
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
				AND files.parser_version < ?),
			EXISTS (SELECT 1 FROM files WHERE files.session_uuid = s.session_uuid)
				AND NOT EXISTS (SELECT 1 FROM files WHERE files.session_uuid = s.session_uuid
				AND files.parser_version < ?)
		FROM agent_log_sessions s
		WHERE s.project_id = ? AND (s.started_at >= ? OR s.ended_at >= ?)
		ORDER BY s.started_at, s.session_uuid`,
		[]any{projectID, projectID, agentReportMinParserVersion, agentReportFactsParserVersion, projectID, since, since},
		func(r *sql.Rows) error {
			var s AgentReportSession
			if err := r.Scan(&s.SessionUUID, &s.StartedAt, &s.EndedAt, &s.Model, &s.GitBranch, &s.OldFormat, &s.Facts); err != nil {
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
			src_path, src_offset, error_class, result_bytes, thinking_tokens, pre_tokens, post_tokens, skill
			FROM agent_log_events WHERE session_uuid IN (?`+strings.Repeat(",?", len(chunk)-1)+`)
			ORDER BY session_uuid, ts, src_path, src_offset, key`, args,
			func(r *sql.Rows) error {
				var e AgentReportEvent
				var dur, resultBytes, pre, post sql.NullInt64
				if err := r.Scan(&e.SessionUUID, &e.Kind, &e.TS, &e.AgentID, &e.Name, &e.Target, &e.Trigger, &e.Outcome,
					&e.SpawnedAgentID, &e.Background, &dur, &e.CostUSD, &e.CostEstimated,
					&e.InputTokens, &e.OutputTokens, &e.CacheReadTokens, &e.CacheWrite5mTokens, &e.CacheWrite1hTokens,
					&e.SrcPath, &e.SrcOffset, &e.ErrorClass, &resultBytes, &e.ThinkingTokens, &pre, &post, &e.Skill); err != nil {
					return err
				}
				if dur.Valid {
					e.DurationMS = &dur.Int64
				}
				if resultBytes.Valid {
					e.ResultBytes = &resultBytes.Int64
				}
				if pre.Valid {
					e.PreTokens = &pre.Int64
				}
				if post.Valid {
					e.PostTokens = &post.Int64
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

// agentReportByUUIDs runs query (which must end with "session_uuid IN (%s)" and
// carry its own ORDER BY) per chunk of the sorted ids, so the overall order
// holds.
func (d *DB) agentReportByUUIDs(uuids []string, query string, scan func(*sql.Rows) error) error {
	ids := slices.Clone(uuids)
	slices.Sort(ids)
	for len(ids) > 0 {
		n := min(len(ids), agentReportChunk)
		args := make([]any, n)
		for i, id := range ids[:n] {
			args[i] = id
		}
		ids = ids[n:]
		if err := d.agentLogRows(fmt.Sprintf(query, "?"+strings.Repeat(",?", n-1)), args, scan); err != nil {
			return err
		}
	}
	return nil
}

// AgentReportContextParts returns the baseline parts of the given sessions,
// ordered by session, agent id, part.
func (d *DB) AgentReportContextParts(uuids []string) ([]AgentContextPart, error) {
	out := []AgentContextPart{}
	err := d.agentReportByUUIDs(uuids, `SELECT session_uuid, agent_id, part, bytes FROM agent_log_context_parts
		WHERE session_uuid IN (%s) ORDER BY session_uuid, agent_id, part`, func(r *sql.Rows) error {
		var p AgentContextPart
		if err := r.Scan(&p.SessionUUID, &p.AgentID, &p.Part, &p.Bytes); err != nil {
			return err
		}
		out = append(out, p)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("agent report context parts: %w", err)
	}
	return out, nil
}

// AgentReportSkillListing returns the skills listed in the given sessions'
// context, ordered by session, skill.
func (d *DB) AgentReportSkillListing(uuids []string) ([]AgentSkillListed, error) {
	out := []AgentSkillListed{}
	err := d.agentReportByUUIDs(uuids, `SELECT session_uuid, skill, bytes FROM agent_log_skill_listing
		WHERE session_uuid IN (%s) ORDER BY session_uuid, skill`, func(r *sql.Rows) error {
		var k AgentSkillListed
		if err := r.Scan(&k.SessionUUID, &k.Skill, &k.Bytes); err != nil {
			return err
		}
		out = append(out, k)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("agent report skill listing: %w", err)
	}
	return out, nil
}

// AgentReportSubagents returns the sub-agent lanes of the given sessions,
// ordered by session, agent id.
func (d *DB) AgentReportSubagents(uuids []string) ([]AgentSubagent, error) {
	out := []AgentSubagent{}
	err := d.agentReportByUUIDs(uuids, `SELECT session_uuid, agent_id, agent_type, depth, finished FROM agent_log_subagents
		WHERE session_uuid IN (%s) ORDER BY session_uuid, agent_id`, func(r *sql.Rows) error {
		var a AgentSubagent
		var fin sql.NullBool
		if err := r.Scan(&a.SessionUUID, &a.AgentID, &a.AgentType, &a.Depth, &fin); err != nil {
			return err
		}
		if fin.Valid {
			a.Finished = &fin.Bool
		}
		out = append(out, a)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("agent report subagents: %w", err)
	}
	return out, nil
}
