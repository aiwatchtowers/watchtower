// Package agentreport turns the stored agent-log events of a workbench into
// the #298 history report: where a session's wall time went, how its
// subagents overlapped. It is pure: the caller loads the rows (internal/db).
package agentreport

import "time"

// AwayAfter is how much of one uncovered wait counts as waiting for the owner;
// the rest is away and stays out of active time.
const AwayAfter = 30 * time.Minute

// Categories of a stretch of wall time.
const (
	CatModel      = "model"
	CatTool       = "tool"
	CatBackground = "background"
	CatOwner      = "owner"
	CatAway       = "away"
)

// ToolTimes is tool time by class, in ms.
type ToolTimes struct {
	BuildTest   int64 `json:"build_test"`
	Git         int64 `json:"git"`
	ReadSearch  int64 `json:"read_search"`
	Edit        int64 `json:"edit"`
	MCP         int64 `json:"mcp"`
	SubagentsFG int64 `json:"subagents_fg"`
	Other       int64 `json:"other"`
}

// TimeSplit is a session's wall time by category; every field but ActiveMS
// and WallMS adds up to WallMS, and ActiveMS = WallMS - AwayMS.
type TimeSplit struct {
	ModelMS      int64     `json:"model_ms"`
	Tools        ToolTimes `json:"tools"`
	BackgroundMS int64     `json:"background_ms"`
	OwnerMS      int64     `json:"owner_ms"`
	AwayMS       int64     `json:"away_ms"`
	ActiveMS     int64     `json:"active_ms"`
	WallMS       int64     `json:"wall_ms"`
}

// Subagents measures how a session's subagents overlapped.
type Subagents struct {
	Count       int     `json:"count"`
	Foreground  int     `json:"foreground"`
	Background  int     `json:"background"`
	Peak        int     `json:"peak"`
	Serial      int     `json:"serial"`     // foreground subagents whose span overlaps no other
	BusyMS      int64   `json:"busy_ms"`    // sum of the spans
	UnionMS     int64   `json:"union_ms"`   // union of the spans
	BlockedMS   int64   `json:"blocked_ms"` // main agent in foreground subagent calls
	AvgParallel float64 `json:"avg_parallel"`
}

// Segment is one stretch of a lane; Start and End are UTC RFC 3339 with ms.
type Segment struct {
	Start     string `json:"start"`
	End       string `json:"end"`
	Category  string `json:"category"`
	ToolClass string `json:"tool_class"`
	Verb      string `json:"verb"`
}

// Lane is one agent's timeline; AgentID "" is the main agent.
type Lane struct {
	AgentID      string    `json:"agent_id"`
	SubagentType string    `json:"subagent_type"`
	Background   bool      `json:"background"`
	Segments     []Segment `json:"segments"`
}

// plus adds the counts and times of u; Peak is the larger and AvgParallel is
// BusyMS / UnionMS again.
func (s *Subagents) plus(u Subagents) {
	s.Count += u.Count
	s.Foreground += u.Foreground
	s.Background += u.Background
	s.Peak = max(s.Peak, u.Peak)
	s.Serial += u.Serial
	s.BusyMS += u.BusyMS
	s.UnionMS += u.UnionMS
	s.BlockedMS += u.BlockedMS
	s.AvgParallel = 0
	if s.UnionMS > 0 {
		s.AvgParallel = float64(s.BusyMS) / float64(s.UnionMS)
	}
}
