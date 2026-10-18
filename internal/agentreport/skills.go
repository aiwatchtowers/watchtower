package agentreport

import (
	"cmp"
	"math"
	"slices"
	"time"

	"watchtower/internal/agentlogdb"
)

// SkillsReport is the period's skills: how many were listed in the sessions'
// context and how many were used, a row per used skill, and the never-used
// ones with what their listing costs. ListingTokens is the median per session
// of the whole listing. Only the sessions with the v2 facts (FactsSessions)
// are measured.
type SkillsReport struct {
	FactsSessions int           `json:"facts_sessions"`
	Listed        int           `json:"listed"`
	Used          int           `json:"used"`
	ListingTokens int64         `json:"listing_tokens"`
	Rows          []SkillRow    `json:"rows"`
	NeverUsed     []UnusedSkill `json:"never_used"`

	span time.Duration // first start to last end of the measured sessions (S1)
}

// SkillRow is one used skill: its invocations by trigger (proactive = a Skill
// call, slash = the owner's /command, read = its SKILL.md read), the cost of
// the API calls made under it and the sessions it was used in.
type SkillRow struct {
	Name        string         `json:"name"`
	Invocations int            `json:"invocations"`
	ByTrigger   map[string]int `json:"by_trigger"`
	CostUSD     float64        `json:"cost_usd"`
	Sessions    int            `json:"sessions"`

	last string // the last session counted
}

// UnusedSkill is a skill listed in the period's sessions and never used;
// ListingTokens is the median per session it was listed in.
type UnusedSkill struct {
	Name          string `json:"name"`
	ListingTokens int64  `json:"listing_tokens"`

	total int64 // its listing tokens over every session (S1's estimate)
}

// Skills measures the period's skills from the sessions' events (keyed by
// uuid), their baseline parts (for the main lane's tokens per byte, as in
// Context) and their skill listing. Sessions without the v2 facts are skipped.
func Skills(sessions []agentlogdb.AgentReportSession, events map[string][]agentlogdb.AgentReportEvent,
	parts []agentlogdb.AgentContextPart, listing []agentlogdb.AgentSkillListed) SkillsReport {
	r := SkillsReport{Rows: []SkillRow{}, NeverUsed: []UnusedSkill{}}
	rows := map[string]*SkillRow{}
	use := func(name, sid string) *SkillRow {
		row := rows[name]
		if row == nil {
			row = &SkillRow{Name: name, ByTrigger: map[string]int{"proactive": 0, "slash": 0, "read": 0}}
			rows[name] = row
		}
		if row.last != sid {
			row.last = sid
			row.Sessions++
		}
		return row
	}
	partsFor := groupParts(parts)
	perToken := map[string]float64{}
	var first, last time.Time
	for _, s := range sessions {
		if !s.Facts {
			continue
		}
		r.FactsSessions++
		if t, err := time.Parse(time.RFC3339Nano, s.StartedAt); err == nil && (first.IsZero() || t.Before(first)) {
			first = t
		}
		if t, err := time.Parse(time.RFC3339Nano, s.EndedAt); err == nil && t.After(last) {
			last = t
		}
		var firstCtx int64
		for _, e := range events[s.SessionUUID] {
			switch {
			case e.Kind == "skill" && e.Name != "":
				row := use(e.Name, s.SessionUUID)
				row.Invocations++
				row.ByTrigger[e.Trigger]++
			case e.Kind == "api_call":
				if firstCtx == 0 && e.AgentID == "" {
					firstCtx = ctxTokens(e)
				}
				if e.Skill != "" {
					use(e.Skill, s.SessionUUID).CostUSD += e.CostUSD
				}
			}
		}
		perToken[s.SessionUUID] = tokensPerByte(partsFor[s.SessionUUID], "", firstCtx)
	}
	if !first.IsZero() && last.After(first) {
		r.span = last.Sub(first)
	}

	perSkill := map[string][]int64{}
	var perSession []int64
	prev := ""
	for _, k := range listing { // ordered by session
		pt, ok := perToken[k.SessionUUID]
		if !ok {
			continue
		}
		tok := int64(math.Round(float64(max(k.Bytes, 0)) * pt))
		perSkill[k.Skill] = append(perSkill[k.Skill], tok)
		if k.SessionUUID != prev {
			prev = k.SessionUUID
			perSession = append(perSession, 0)
		}
		perSession[len(perSession)-1] += tok
	}
	r.Listed = len(perSkill)
	r.ListingTokens = median(perSession)
	for name, toks := range perSkill {
		if rows[name] != nil {
			continue
		}
		u := UnusedSkill{Name: name, ListingTokens: median(toks)}
		for _, t := range toks {
			u.total += t
		}
		r.NeverUsed = append(r.NeverUsed, u)
	}
	slices.SortFunc(r.NeverUsed, func(x, y UnusedSkill) int {
		return cmp.Or(cmp.Compare(y.ListingTokens, x.ListingTokens), cmp.Compare(x.Name, y.Name))
	})
	for _, row := range rows {
		r.Rows = append(r.Rows, *row)
	}
	slices.SortFunc(r.Rows, func(x, y SkillRow) int {
		return cmp.Or(cmp.Compare(y.Invocations, x.Invocations), cmp.Compare(y.CostUSD, x.CostUSD), cmp.Compare(x.Name, y.Name))
	})
	r.Used = len(r.Rows)
	return r
}
