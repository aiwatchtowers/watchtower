package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// AgentLogFile is one agent_log_files row: a transcript's scan state.
type AgentLogFile struct {
	Path, Agent   string
	Size          int64
	MTime         string
	ReadOffset    int64
	ParserVersion int
	MissingAt     string // "" = present
}

// AgentLogSession is one agent_log_sessions row (upserted per batch).
type AgentLogSession struct {
	SessionUUID, Agent, FolderPath, HomeCWD, SourcePath, GitBranch, Model, StartedAt, EndedAt string
	ProjectID                                                                                 *int64
	ReportedCostUSD                                                                           *float64
}

// AgentLogEvent is one agent_log_events row, unique by Key.
type AgentLogEvent struct {
	SessionUUID, Key, Kind, TS, UUID, ParentUUID, PromptID, AgentID                    string
	IsSidechain                                                                        bool
	Name, Target, Trigger, Outcome, ErrorClass, Skill                                  string
	InputTokens, OutputTokens, CacheReadTokens, CacheWrite5mTokens, CacheWrite1hTokens int64
	Speed, ServiceTier                                                                 string
	CostUSD                                                                            float64
	PriceVersion                                                                       int
	CostEstimated                                                                      bool
	LinesAdded, LinesRemoved                                                           int
	SrcPath                                                                            string
	SrcOffset                                                                          int64
	MessageID                                                                          string // api_call only, not stored
	SpawnedAgentID                                                                     string // Agent tool call: the sub-agent's id, set when the result pairs
	Background                                                                         bool
	SubagentReplayCheck                                                                bool // skip when the session already has this message.id under another key
}

// AgentToolResult pairs a tool_result with its stored `tool:<ToolUseID>` event.
type AgentToolResult struct {
	ToolUseID, TS, Outcome, ErrorClass string
	LinesAdded, LinesRemoved           int
	SpawnedAgentID                     string
	Background                         bool
}

// AgentLogBatch is what one parse of one file writes in one transaction.
type AgentLogBatch struct {
	File         AgentLogFile // Path, Agent, Size, MTime, ParserVersion; ReadOffset = the new offset
	ExpectOffset int64        // compare-and-set: the offset the caller read from; -1 = file row must not exist
	Sessions     []AgentLogSession
	Events       []AgentLogEvent
	ToolResults  []AgentToolResult
}

// AgentLogStats is a workbench's totals for `agents stats --json` (pinned keys).
type AgentLogStats struct {
	Sessions           int                   `json:"sessions"`
	Tokens             AgentLogTokens        `json:"tokens"`
	CostUSD            float64               `json:"cost_usd"`
	CostEstimatedCalls int                   `json:"cost_estimated_calls"`
	ReportedCostUSD    float64               `json:"reported_cost_usd"`
	OwnerTurns         int                   `json:"owner_turns"`
	Tools              []AgentLogCount       `json:"tools"`
	Outcomes           map[string]int        `json:"outcomes"`
	Skills             []AgentLogSkill       `json:"skills"`
	PerSession         []AgentLogSessionStat `json:"per_session"`
}

// AgentLogTokens sums the token buckets of api_call events.
type AgentLogTokens struct {
	Input        int64 `json:"input"`
	Output       int64 `json:"output"`
	CacheRead    int64 `json:"cache_read"`
	CacheWrite5m int64 `json:"cache_write_5m"`
	CacheWrite1h int64 `json:"cache_write_1h"`
}

// AgentLogCount is a name and how often it occurred.
type AgentLogCount struct {
	Name  string `json:"name"`
	Count int    `json:"count"`
}

// AgentLogSkill counts one skill's activations per trigger.
type AgentLogSkill struct {
	Name      string `json:"name"`
	Proactive int    `json:"proactive"`
	Slash     int    `json:"slash"`
	Read      int    `json:"read"`
}

// AgentLogSessionStat is one session's line in AgentLogStats.PerSession.
type AgentLogSessionStat struct {
	SessionUUID     string   `json:"session_uuid"`
	StartedAt       string   `json:"started_at"`
	EndedAt         string   `json:"ended_at"`
	Model           string   `json:"model"`
	APICalls        int      `json:"api_calls"`
	CostUSD         float64  `json:"cost_usd"`
	ReportedCostUSD *float64 `json:"reported_cost_usd"`
	ToolErrors      int      `json:"tool_errors"`
}

const agentLogFileCols = `path, agent, size, mtime, read_offset, parser_version, COALESCE(missing_at, '')`

func scanAgentLogFile(row interface{ Scan(...any) error }) (*AgentLogFile, error) {
	var f AgentLogFile
	if err := row.Scan(&f.Path, &f.Agent, &f.Size, &f.MTime, &f.ReadOffset, &f.ParserVersion, &f.MissingAt); err != nil {
		return nil, err
	}
	return &f, nil
}

// GetAgentLogFile returns the stored scan state of path, or nil when the file
// was never scanned.
func (db *DB) GetAgentLogFile(path string) (*AgentLogFile, error) {
	f, err := scanAgentLogFile(db.QueryRow(`SELECT `+agentLogFileCols+` FROM agent_log_files WHERE path = ?`, path))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("getting agent log file: %w", err)
	}
	return f, nil
}

// AgentLogFilesUnder lists stored files whose path lies under one of dirs.
func (db *DB) AgentLogFilesUnder(dirs []string) ([]AgentLogFile, error) {
	var out []AgentLogFile
	for _, dir := range dirs {
		prefix := strings.TrimSuffix(dir, "/") + "/"
		err := db.agentLogRows(`SELECT `+agentLogFileCols+` FROM agent_log_files WHERE path >= ? AND path < ?`,
			[]any{prefix, prefix + "\uffff"}, func(r *sql.Rows) error {
				f, err := scanAgentLogFile(r)
				if err != nil {
					return err
				}
				out = append(out, *f)
				return nil
			})
		if err != nil {
			return nil, fmt.Errorf("listing agent log files: %w", err)
		}
	}
	return out, nil
}

// MarkAgentLogFileMissing records that path is gone; its rows stay (AGENTLOG-03).
func (db *DB) MarkAgentLogFileMissing(path, at string) error {
	_, err := db.Exec(`UPDATE agent_log_files SET missing_at = ? WHERE path = ? AND missing_at IS NULL`, at, path)
	return err
}

// ApplyAgentLogBatch writes one parsed slice of a transcript in a single
// transaction and advances the file's offset with a compare-and-set. It
// returns applied=false (nothing written) when another writer moved the
// offset first.
func (db *DB) ApplyAgentLogBatch(b AgentLogBatch) (bool, error) {
	applied := false
	err := db.WithTx(func(tx *sql.Tx) error {
		var res sql.Result
		var err error
		if b.ExpectOffset < 0 {
			res, err = tx.Exec(`INSERT INTO agent_log_files (path, agent, size, mtime, read_offset, parser_version, scanned_at)
				VALUES (?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now')) ON CONFLICT(path) DO NOTHING`,
				b.File.Path, b.File.Agent, b.File.Size, b.File.MTime, b.File.ReadOffset, b.File.ParserVersion)
		} else {
			res, err = tx.Exec(`UPDATE agent_log_files SET size = ?, mtime = ?, read_offset = ?, parser_version = ?,
				missing_at = NULL, scanned_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE path = ? AND read_offset = ?`,
				b.File.Size, b.File.MTime, b.File.ReadOffset, b.File.ParserVersion, b.File.Path, b.ExpectOffset)
		}
		if err != nil {
			return fmt.Errorf("advancing agent log file: %w", err)
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return errCASLost
		}
		for _, s := range b.Sessions {
			if err := upsertAgentLogSession(tx, s); err != nil {
				return err
			}
		}
		for _, e := range b.Events {
			if err := upsertAgentLogEvent(tx, e); err != nil {
				return err
			}
		}
		for _, r := range b.ToolResults {
			if _, err := tx.Exec(`UPDATE agent_log_events SET outcome = ?, error_class = ?,
				lines_added = ?, lines_removed = ?,
				duration_ms = CAST(ROUND((julianday(?) - julianday(ts)) * 86400000) AS INTEGER)
				WHERE key = ?`, r.Outcome, r.ErrorClass, r.LinesAdded, r.LinesRemoved, r.TS, "tool:"+r.ToolUseID); err != nil {
				return fmt.Errorf("pairing tool result: %w", err)
			}
			if r.SpawnedAgentID != "" {
				if _, err := tx.Exec(`UPDATE agent_log_events SET spawned_agent_id = ?, background = ? WHERE key = ?`,
					r.SpawnedAgentID, r.Background, "tool:"+r.ToolUseID); err != nil {
					return fmt.Errorf("pairing spawned agent: %w", err)
				}
			} else if r.Background {
				if _, err := tx.Exec(`UPDATE agent_log_events SET background = 1 WHERE key = ?`, "tool:"+r.ToolUseID); err != nil {
					return fmt.Errorf("pairing background flag: %w", err)
				}
			}
		}
		applied = true
		return nil
	})
	if errors.Is(err, errCASLost) {
		return false, nil
	}
	return applied, err
}

var errCASLost = errors.New("agent log offset moved by another writer")

func upsertAgentLogSession(tx *sql.Tx, s AgentLogSession) error {
	_, err := tx.Exec(`INSERT INTO agent_log_sessions (session_uuid, agent, project_id, folder_path, home_cwd,
		terminal_session_id, source_path, git_branch, model, started_at, ended_at, reported_cost_usd)
		VALUES (?, ?, ?, ?, ?, (SELECT id FROM terminal_sessions WHERE claude_session_id = ? AND kind = 'claude' LIMIT 1),
		        ?, ?, ?, ?, ?, ?)
		ON CONFLICT(session_uuid) DO UPDATE SET
		  model = CASE WHEN excluded.model <> '' AND excluded.ended_at >= agent_log_sessions.ended_at
		               THEN excluded.model ELSE agent_log_sessions.model END,
		  started_at = MIN(agent_log_sessions.started_at, excluded.started_at),
		  ended_at = MAX(agent_log_sessions.ended_at, excluded.ended_at),
		  git_branch = CASE WHEN agent_log_sessions.git_branch = '' THEN excluded.git_branch ELSE agent_log_sessions.git_branch END,
		  project_id = COALESCE(agent_log_sessions.project_id, excluded.project_id),
		  terminal_session_id = COALESCE(agent_log_sessions.terminal_session_id, excluded.terminal_session_id),
		  reported_cost_usd = COALESCE(excluded.reported_cost_usd, agent_log_sessions.reported_cost_usd)`,
		s.SessionUUID, s.Agent, s.ProjectID, s.FolderPath, s.HomeCWD, s.SessionUUID,
		s.SourcePath, s.GitBranch, s.Model, s.StartedAt, s.EndedAt, s.ReportedCostUSD)
	if err != nil {
		return fmt.Errorf("upserting agent log session: %w", err)
	}
	return nil
}

func upsertAgentLogEvent(tx *sql.Tx, e AgentLogEvent) error {
	if e.SubagentReplayCheck && e.MessageID != "" {
		var n int
		prefix := e.MessageID + ":"
		if err := tx.QueryRow(`SELECT COUNT(*) FROM agent_log_events WHERE session_uuid = ? AND kind = 'api_call'
			AND key >= ? AND key < ? AND key <> ?`, e.SessionUUID, prefix, prefix+"￿", e.Key).Scan(&n); err != nil {
			return err
		}
		if n > 0 {
			return nil
		}
	}
	// Ownership: the earliest session (tie → smaller uuid) keeps a replayed key.
	_, err := tx.Exec(`INSERT INTO agent_log_events (session_uuid, key, kind, ts, uuid, parent_uuid, prompt_id, agent_id,
		is_sidechain, name, target, trigger, outcome, error_class, skill, input_tokens, output_tokens, cache_read_tokens,
		cache_write_5m_tokens, cache_write_1h_tokens, speed, service_tier, cost_usd, price_version, cost_estimated,
		lines_added, lines_removed, src_path, src_offset, spawned_agent_id, background)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(key) DO UPDATE SET
		  session_uuid = CASE WHEN (SELECT started_at FROM agent_log_sessions WHERE session_uuid = excluded.session_uuid)
		                           < (SELECT started_at FROM agent_log_sessions WHERE session_uuid = agent_log_events.session_uuid)
		                      OR ((SELECT started_at FROM agent_log_sessions WHERE session_uuid = excluded.session_uuid)
		                           = (SELECT started_at FROM agent_log_sessions WHERE session_uuid = agent_log_events.session_uuid)
		                          AND excluded.session_uuid < agent_log_events.session_uuid)
		                 THEN excluded.session_uuid ELSE agent_log_events.session_uuid END,
		  input_tokens = CASE WHEN excluded.output_tokens >= agent_log_events.output_tokens THEN excluded.input_tokens ELSE agent_log_events.input_tokens END,
		  cache_read_tokens = CASE WHEN excluded.output_tokens >= agent_log_events.output_tokens THEN excluded.cache_read_tokens ELSE agent_log_events.cache_read_tokens END,
		  cache_write_5m_tokens = CASE WHEN excluded.output_tokens >= agent_log_events.output_tokens THEN excluded.cache_write_5m_tokens ELSE agent_log_events.cache_write_5m_tokens END,
		  cache_write_1h_tokens = CASE WHEN excluded.output_tokens >= agent_log_events.output_tokens THEN excluded.cache_write_1h_tokens ELSE agent_log_events.cache_write_1h_tokens END,
		  cost_usd = CASE WHEN excluded.output_tokens >= agent_log_events.output_tokens THEN excluded.cost_usd ELSE agent_log_events.cost_usd END,
		  output_tokens = MAX(agent_log_events.output_tokens, excluded.output_tokens),
		  trigger = CASE WHEN excluded.trigger <> '' THEN excluded.trigger ELSE agent_log_events.trigger END,
		  target = CASE WHEN excluded.target <> '' THEN excluded.target ELSE agent_log_events.target END,
		  background = MAX(agent_log_events.background, excluded.background),
		  outcome = CASE WHEN agent_log_events.outcome IN ('', 'pending') THEN excluded.outcome ELSE agent_log_events.outcome END`,
		e.SessionUUID, e.Key, e.Kind, e.TS, e.UUID, e.ParentUUID, e.PromptID, e.AgentID, e.IsSidechain,
		e.Name, e.Target, e.Trigger, e.Outcome, e.ErrorClass, e.Skill, e.InputTokens, e.OutputTokens, e.CacheReadTokens,
		e.CacheWrite5mTokens, e.CacheWrite1hTokens, e.Speed, e.ServiceTier, e.CostUSD, e.PriceVersion, e.CostEstimated,
		e.LinesAdded, e.LinesRemoved, e.SrcPath, e.SrcOffset, e.SpawnedAgentID, e.Background)
	if err != nil {
		return fmt.Errorf("upserting agent log event: %w", err)
	}
	return nil
}

// SetWorkbenchAgentAnalytics turns analytics on or off for a workbench.
func (db *DB) SetWorkbenchAgentAnalytics(id int64, on bool) error {
	res, err := db.Exec(`UPDATE projects SET agent_analytics = ? WHERE id = ?`, on, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("workbench %d: %w", id, ErrWorkbenchNotFound)
	}
	return nil
}

func (db *DB) WorkbenchAgentAnalytics(id int64) (bool, error) {
	var on bool
	err := db.QueryRow(`SELECT agent_analytics FROM projects WHERE id = ?`, id).Scan(&on)
	if errors.Is(err, sql.ErrNoRows) {
		return false, fmt.Errorf("workbench %d: %w", id, ErrWorkbenchNotFound)
	}
	return on, err
}

func (db *DB) AgentAnalyticsWorkbenchIDs() ([]int64, error) {
	rows, err := db.Query(`SELECT id FROM projects WHERE agent_analytics = 1 ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// AdoptAgentLogSessions links orphaned sessions (their workbench was
// deleted, PROJ-02 exception) to a workbench bound to the same folder.
func (db *DB) AdoptAgentLogSessions(projectID int64, folder string) (int64, error) {
	res, err := db.Exec(`UPDATE agent_log_sessions SET project_id = ? WHERE project_id IS NULL AND folder_path = ? COLLATE NOCASE`, projectID, folder)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// AgentLogSessionFolder returns the folder a stored session was matched to.
func (db *DB) AgentLogSessionFolder(sessionUUID string) (string, bool, error) {
	var folder string
	err := db.QueryRow(`SELECT folder_path FROM agent_log_sessions WHERE session_uuid = ?`, sessionUUID).Scan(&folder)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	return folder, err == nil, err
}

// RepriceAgentLogEvents recomputes cost for api_call rows priced with an
// older table version, from their stored tokens.
func (db *DB) RepriceAgentLogEvents(version int, price func(model, speed string, in, out, cacheRead, cw5m, cw1h int64) (float64, bool)) (int, error) {
	type row struct {
		id                     int64
		model, speed           string
		in, out, cr, cw5, cw1h int64
	}
	var todo []row
	err := db.agentLogRows(`SELECT id, name, speed, input_tokens, output_tokens, cache_read_tokens, cache_write_5m_tokens,
		cache_write_1h_tokens FROM agent_log_events WHERE kind = 'api_call' AND price_version < ?`, []any{version},
		func(rs *sql.Rows) error {
			var r row
			if err := rs.Scan(&r.id, &r.model, &r.speed, &r.in, &r.out, &r.cr, &r.cw5, &r.cw1h); err != nil {
				return err
			}
			todo = append(todo, r)
			return nil
		})
	if err != nil {
		return 0, err
	}
	err = db.WithTx(func(tx *sql.Tx) error {
		for _, r := range todo {
			usd, known := price(r.model, r.speed, r.in, r.out, r.cr, r.cw5, r.cw1h)
			if _, err := tx.Exec(`UPDATE agent_log_events SET cost_usd = ?, cost_estimated = ?, price_version = ? WHERE id = ?`,
				usd, !known, version, r.id); err != nil {
				return err
			}
		}
		return nil
	})
	return len(todo), err
}

// AgentLogStats aggregates the stored analytics of one workbench.
func (db *DB) AgentLogStats(projectID int64) (*AgentLogStats, error) {
	st := &AgentLogStats{Tools: []AgentLogCount{}, Outcomes: map[string]int{}, Skills: []AgentLogSkill{}, PerSession: []AgentLogSessionStat{}}
	err := db.QueryRow(`SELECT COUNT(*), COALESCE(SUM(t.input_tokens),0), COALESCE(SUM(t.output_tokens),0),
		COALESCE(SUM(t.cache_read_tokens),0), COALESCE(SUM(t.cache_write_5m_tokens),0), COALESCE(SUM(t.cache_write_1h_tokens),0),
		COALESCE(SUM(t.cost_usd),0), COALESCE(SUM(t.cost_estimated_calls),0), COALESCE(SUM(t.owner_turns),0),
		COALESCE(SUM(s.reported_cost_usd),0)
		FROM agent_log_sessions s LEFT JOIN agent_log_session_totals t ON t.session_uuid = s.session_uuid
		WHERE s.project_id = ?`, projectID).Scan(&st.Sessions, &st.Tokens.Input, &st.Tokens.Output, &st.Tokens.CacheRead,
		&st.Tokens.CacheWrite5m, &st.Tokens.CacheWrite1h, &st.CostUSD, &st.CostEstimatedCalls, &st.OwnerTurns, &st.ReportedCostUSD)
	if err != nil {
		return nil, fmt.Errorf("agent log totals: %w", err)
	}
	if err := db.agentLogRows(`SELECT e.name, COUNT(*) FROM agent_log_events e JOIN agent_log_sessions s ON s.session_uuid = e.session_uuid
		WHERE s.project_id = ? AND e.kind = 'tool' GROUP BY e.name ORDER BY COUNT(*) DESC, e.name LIMIT 20`, []any{projectID},
		func(r *sql.Rows) error {
			var c AgentLogCount
			if err := r.Scan(&c.Name, &c.Count); err != nil {
				return err
			}
			st.Tools = append(st.Tools, c)
			return nil
		}); err != nil {
		return nil, fmt.Errorf("agent log tools: %w", err)
	}
	if err := db.agentLogRows(`SELECT e.outcome, COUNT(*) FROM agent_log_events e JOIN agent_log_sessions s ON s.session_uuid = e.session_uuid
		WHERE s.project_id = ? AND e.kind = 'tool' GROUP BY e.outcome`, []any{projectID},
		func(r *sql.Rows) error {
			var o string
			var n int
			if err := r.Scan(&o, &n); err != nil {
				return err
			}
			st.Outcomes[o] = n
			return nil
		}); err != nil {
		return nil, fmt.Errorf("agent log outcomes: %w", err)
	}
	if err := db.agentLogRows(`SELECT e.name, COALESCE(SUM(e.trigger = 'proactive'),0), COALESCE(SUM(e.trigger = 'slash'),0),
		COALESCE(SUM(e.trigger = 'read'),0)
		FROM agent_log_events e JOIN agent_log_sessions s ON s.session_uuid = e.session_uuid
		WHERE s.project_id = ? AND e.kind = 'skill' GROUP BY e.name ORDER BY COUNT(*) DESC, e.name`, []any{projectID},
		func(r *sql.Rows) error {
			var k AgentLogSkill
			if err := r.Scan(&k.Name, &k.Proactive, &k.Slash, &k.Read); err != nil {
				return err
			}
			st.Skills = append(st.Skills, k)
			return nil
		}); err != nil {
		return nil, fmt.Errorf("agent log skills: %w", err)
	}
	if err := db.agentLogRows(`SELECT s.session_uuid, s.started_at, s.ended_at, s.model, COALESCE(t.api_calls,0),
		COALESCE(t.cost_usd,0), s.reported_cost_usd, COALESCE(t.tool_errors,0)
		FROM agent_log_sessions s LEFT JOIN agent_log_session_totals t ON t.session_uuid = s.session_uuid
		WHERE s.project_id = ? ORDER BY s.started_at DESC LIMIT 50`, []any{projectID},
		func(r *sql.Rows) error {
			var p AgentLogSessionStat
			if err := r.Scan(&p.SessionUUID, &p.StartedAt, &p.EndedAt, &p.Model, &p.APICalls, &p.CostUSD, &p.ReportedCostUSD, &p.ToolErrors); err != nil {
				return err
			}
			st.PerSession = append(st.PerSession, p)
			return nil
		}); err != nil {
		return nil, fmt.Errorf("agent log sessions: %w", err)
	}
	return st, nil
}

func (db *DB) agentLogRows(q string, args []any, each func(*sql.Rows) error) error {
	rows, err := db.Query(q, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		if err := each(rows); err != nil {
			return err
		}
	}
	return rows.Err()
}
