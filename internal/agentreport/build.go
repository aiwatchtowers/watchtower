package agentreport

import (
	"fmt"
	"slices"
	"time"

	"watchtower/internal/db"
)

// Totals sums the whole window, old-format sessions included for cost and
// tokens; ActiveMS and AwayMS cover the sessions with a time model.
type Totals struct {
	Sessions           int               `json:"sessions"`
	ActiveMS           int64             `json:"active_ms"`
	AwayMS             int64             `json:"away_ms"`
	CostUSD            float64           `json:"cost_usd"`
	CostEstimatedCalls int               `json:"cost_estimated_calls"`
	Tokens             db.AgentLogTokens `json:"tokens"`
}

// SessionRow is one session's line in the overview. An old-format session
// (stored before the parser kept timing) has no time fields.
type SessionRow struct {
	UUID        string   `json:"session_uuid"`
	StartedAt   string   `json:"started_at"`
	EndedAt     string   `json:"ended_at"`
	Model       string   `json:"model"`
	Branch      string   `json:"branch"`
	ActiveMS    int64    `json:"active_ms"`
	CostUSD     float64  `json:"cost_usd"`
	AvgParallel float64  `json:"avg_parallel"`
	OldFormat   bool     `json:"old_format"`
	PRs         []string `json:"prs"`
}

// Overview is the report of one workbench over a period (`agents report --json`).
type Overview struct {
	WorkbenchID       int64        `json:"workbench_id"`
	Enabled           bool         `json:"enabled"`
	Since             string       `json:"since"`
	Until             string       `json:"until"`
	Totals            Totals       `json:"totals"`
	Time              TimeSplit    `json:"time"`
	Subagents         Subagents    `json:"subagents"`
	Commands          []CommandRow `json:"commands"`
	Models            []ModelRow   `json:"models"`
	Hints             []Hint       `json:"hints"`
	Tasks             []TaskRow    `json:"tasks"`
	Sessions          []SessionRow `json:"sessions"`
	OldFormatSessions int          `json:"old_format_sessions"`
}

// SessionDetail is one session's drill-down (`agents report --session`).
type SessionDetail struct {
	Session   SessionRow   `json:"session"`
	Time      TimeSplit    `json:"time"`
	Subagents Subagents    `json:"subagents"`
	Hints     []Hint       `json:"hints"`
	Lanes     []Lane       `json:"lanes"`
	Commands  []CommandRow `json:"commands"`
}

// built is everything BuildOverview and BuildSession derive from the rows.
type built struct {
	rows     []SessionRow
	views    map[string]SessionView
	events   map[string][]db.AgentReportEvent // sessions with a time model only
	segments map[string][]Segment
	time     map[string]TimeSplit
	subs     map[string]Subagents
	lanes    map[string][]Lane
	totals   Totals
}

// assemble models every session of sessions; allEvents are keyed by uuid.
func assemble(sessions []db.AgentReportSession, allEvents map[string][]db.AgentReportEvent) built {
	b := built{
		rows: []SessionRow{}, views: map[string]SessionView{}, events: map[string][]db.AgentReportEvent{},
		segments: map[string][]Segment{}, time: map[string]TimeSplit{}, subs: map[string]Subagents{}, lanes: map[string][]Lane{},
	}
	for _, s := range sessions {
		evs := allEvents[s.SessionUUID]
		row := SessionRow{UUID: s.SessionUUID, StartedAt: s.StartedAt, EndedAt: s.EndedAt, Model: s.Model,
			Branch: s.GitBranch, OldFormat: s.OldFormat, PRs: []string{}}
		var in, out, read, w5m, w1h int64
		compactions := 0
		for _, e := range evs {
			switch e.Kind {
			case "api_call":
				row.CostUSD += e.CostUSD
				if e.CostEstimated {
					b.totals.CostEstimatedCalls++
				}
				in += e.InputTokens
				out += e.OutputTokens
				read += e.CacheReadTokens
				w5m += e.CacheWrite5mTokens
				w1h += e.CacheWrite1hTokens
			case "compaction":
				compactions++
			case "pr_link":
				if e.Target != "" && !slices.Contains(row.PRs, e.Target) {
					row.PRs = append(row.PRs, e.Target)
				}
			}
		}
		b.totals.Sessions++
		b.totals.CostUSD += row.CostUSD
		b.totals.Tokens.Input += in
		b.totals.Tokens.Output += out
		b.totals.Tokens.CacheRead += read
		b.totals.Tokens.CacheWrite5m += w5m
		b.totals.Tokens.CacheWrite1h += w1h
		if !s.OldFormat {
			ts, segs := SessionTime(evs)
			sa, lanes := SessionSubagents(evs)
			row.ActiveMS = ts.ActiveMS
			row.AvgParallel = sa.AvgParallel
			b.events[s.SessionUUID] = evs
			b.segments[s.SessionUUID] = segs
			b.time[s.SessionUUID] = ts
			b.subs[s.SessionUUID] = sa
			b.lanes[s.SessionUUID] = lanes
			b.views[s.SessionUUID] = SessionView{UUID: s.SessionUUID, Time: ts, Subagents: sa, CostUSD: row.CostUSD,
				Compactions: compactions, CacheReadShare: cacheReadShare(in, read, w5m, w1h)}
		}
		b.rows = append(b.rows, row)
	}
	return b
}

func nonNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

func eventsByUUID(events []db.AgentReportEvent) map[string][]db.AgentReportEvent {
	by := map[string][]db.AgentReportEvent{}
	for _, e := range events {
		by[e.SessionUUID] = append(by[e.SessionUUID], e)
	}
	return by
}

func flatten(by map[string][]db.AgentReportEvent) []db.AgentReportEvent {
	var out []db.AgentReportEvent
	for _, evs := range by {
		out = append(out, evs...)
	}
	return out
}

// BuildOverview reports a workbench's sessions that started or ended at or
// after since (zero = all) up to now. It answers whatever the analytics
// switch: an off workbench shows the rows it has.
func BuildOverview(d *db.DB, workbenchID int64, since, now time.Time) (*Overview, error) {
	enabled, err := d.WorkbenchAgentAnalytics(workbenchID)
	if err != nil {
		return nil, err
	}
	sinceStr := ""
	ov := &Overview{WorkbenchID: workbenchID, Enabled: enabled, Until: now.UTC().Format(time.RFC3339)}
	if !since.IsZero() {
		sinceStr = since.UTC().Format(tsLayout)
		ov.Since = since.UTC().Format(time.RFC3339)
	}
	sessions, err := d.AgentReportSessions(workbenchID, sinceStr)
	if err != nil {
		return nil, err
	}
	uuids := make([]string, len(sessions))
	for i, s := range sessions {
		uuids[i] = s.SessionUUID
	}
	events, err := d.AgentReportEvents(uuids)
	if err != nil {
		return nil, err
	}
	targets, err := d.AgentReportTargets(workbenchID)
	if err != nil {
		return nil, err
	}
	allEvents := eventsByUUID(events)
	b := assemble(sessions, allEvents)

	for _, r := range b.rows {
		if r.OldFormat {
			ov.OldFormatSessions++
		}
	}
	for _, id := range uuids {
		ts, ok := b.time[id]
		if !ok {
			continue
		}
		ov.Time.plus(ts)
		ov.Subagents.plus(b.subs[id])
	}
	ov.Time.seal()
	ov.Totals = b.totals
	ov.Totals.ActiveMS, ov.Totals.AwayMS = ov.Time.ActiveMS, ov.Time.AwayMS

	ov.Models = nonNil(Models(flatten(allEvents)))
	ov.Commands = nonNil(Commands(flatten(b.events)))
	ov.Tasks = nonNil(Tasks(targets, b.segments, b.events, now))
	ov.Hints = nonNil(Hints(HintInput{Sessions: b.views, Tasks: ov.Tasks, Targets: targets, Events: b.events, Now: now}))
	ov.Sessions = b.rows
	return ov, nil
}

// BuildSession drills into one session of the workbench as of now. Its lanes
// start with the main agent's (AgentID "") unless the session is old-format.
func BuildSession(d *db.DB, workbenchID int64, sessionUUID string, now time.Time) (*SessionDetail, error) {
	all, err := d.AgentReportSessions(workbenchID, "")
	if err != nil {
		return nil, err
	}
	i := slices.IndexFunc(all, func(s db.AgentReportSession) bool { return s.SessionUUID == sessionUUID })
	if i < 0 {
		return nil, fmt.Errorf("session %s not found in workbench %d", sessionUUID, workbenchID)
	}
	events, err := d.AgentReportEvents([]string{sessionUUID})
	if err != nil {
		return nil, err
	}
	targets, err := d.AgentReportTargets(workbenchID)
	if err != nil {
		return nil, err
	}
	by := eventsByUUID(events)
	b := assemble(all[i:i+1], by)
	det := &SessionDetail{Session: b.rows[0], Time: b.time[sessionUUID], Subagents: b.subs[sessionUUID],
		Lanes: []Lane{}, Commands: nonNil(Commands(b.events[sessionUUID]))}
	if segs, ok := b.segments[sessionUUID]; ok {
		det.Lanes = append(det.Lanes, Lane{AgentID: "", Segments: nonNil(segs)})
		det.Lanes = append(det.Lanes, b.lanes[sessionUUID]...)
	}
	tasks := Tasks(targets, b.segments, b.events, now)
	det.Hints = nonNil(Hints(HintInput{Sessions: b.views, Tasks: tasks, Targets: targets, Events: b.events, Now: now}))
	return det, nil
}
