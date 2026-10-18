package agentreport

import (
	"cmp"
	"maps"
	"slices"
	"strings"
	"time"

	"watchtower/internal/agentlog"
	"watchtower/internal/agentlogdb"
)

const (
	// UnfinishedAfter is how long after its session ended a subagent with no
	// finished flag counts as unfinished (before that it may still run).
	UnfinishedAfter = time.Hour
	troubleTopRows  = 10 // rows of denials and interrupt_sessions
	classSessions   = 5  // sessions an error class lists
)

// Denial kinds (error_class of a denied tool call).
const (
	DenialAutoBlocked = "automode-blocked"
	DenialRule        = "permission-rule"
	DenialRejected    = "user-rejected" // the owner said no: a rejection, not a denial
)

// TroubleReport is where the period's agents got stuck: failed calls by
// error class, denied calls, the owner's interrupts and rejections,
// subagents that never finished and rate limits. Only the sessions with the
// v2 facts (FactsSessions) are measured.
type TroubleReport struct {
	Classes             []ErrorClassRow `json:"classes"`
	Denials             []DenialRow     `json:"denials"`
	Interrupts          int             `json:"interrupts"`
	Rejections          int             `json:"rejections"`
	InterruptSessions   []SessionCount  `json:"interrupt_sessions"`
	UnfinishedSubagents int             `json:"unfinished_subagents"`
	RateLimited         int             `json:"rate_limited"`
	FactsSessions       int             `json:"facts_sessions"`

	denials    []denialAgg      // every denial row, uncut (T2)
	interrupts []sessionTrouble // every session with interrupts or rejections, uncut (T3)
}

// ErrorClassRow is one error class: its count, the tool that failed with it
// most and the sessions with the most of it.
type ErrorClassRow struct {
	Class    string         `json:"class"`
	Tool     string         `json:"tool"`
	Count    int            `json:"count"`
	Sessions []SessionCount `json:"sessions"`

	ms        int64 // the failed calls' summed duration (T1's estimate)
	nSessions int   // sessions with the class, Sessions is cut
}

// SessionCount is how often something happened in one session.
type SessionCount struct {
	UUID  string `json:"session_uuid"`
	Count int    `json:"count"`
}

// DenialRow is the denied calls of one kind, tool and target.
type DenialRow struct {
	Kind   string `json:"kind"`
	Tool   string `json:"tool"`
	Target string `json:"target"`
	Count  int    `json:"count"`
}

type denialAgg struct {
	DenialRow
	verb     string         // what an allow rule names: the shell verb, else the tool
	ms       int64          // the denied calls' summed duration
	sessions map[string]int // denied calls per session
}

// sessionTrouble is a session's interrupts plus rejections and the time of
// the work they stopped.
type sessionTrouble struct {
	sid   string
	count int
	ms    int64
}

type classAgg struct {
	ms       int64
	tools    map[string]int
	sessions map[string]int
}

// Trouble measures the period's trouble from the sessions' events (keyed by
// uuid, in AgentReportEvents order: by ts) and their subagents as of now. Sessions without the v2 facts are
// skipped. A subagent counts as unfinished when its meta says so, or when it
// has no finished flag and its session ended over UnfinishedAfter before now.
//
// The work an interrupt stopped runs from the lane's last owner turn (or its
// first event) to the interrupt; a rejected call stops the work since then up
// to its end, and the lane's turn goes on from there.
func Trouble(sessions []agentlogdb.AgentReportSession, events map[string][]agentlogdb.AgentReportEvent,
	subagents []agentlogdb.AgentSubagent, now time.Time) TroubleReport {
	r := TroubleReport{Classes: []ErrorClassRow{}, Denials: []DenialRow{}, InterruptSessions: []SessionCount{}}
	classes := map[string]*classAgg{}
	denials := map[DenialRow]*denialAgg{}
	ended := map[string]string{}
	for _, s := range sessions {
		if !s.Facts {
			continue
		}
		r.FactsSessions++
		ended[s.SessionUUID] = s.EndedAt
		st := sessionTrouble{sid: s.SessionUUID}
		turn := map[string]time.Time{} // per lane: when the current turn started
		for _, e := range events[s.SessionUUID] {
			if _, ok := turn[e.AgentID]; !ok {
				turn[e.AgentID] = parseTS(e.TS)
			}
			switch e.Kind {
			case "tool":
				switch e.Outcome {
				case "error":
					addClass(classes, s.SessionUUID, e)
				case "denied":
					if e.ErrorClass == DenialRejected {
						r.Rejections++
						st.count++
						end := parseTS(e.TS).Add(time.Duration(durMS(e)) * time.Millisecond)
						st.ms += since(turn[e.AgentID], end)
						turn[e.AgentID] = end
						continue
					}
					addDenial(denials, s.SessionUUID, e)
				}
			case "owner_turn":
				at := parseTS(e.TS)
				if e.Trigger == "interrupt" {
					r.Interrupts++
					st.count++
					st.ms += since(turn[e.AgentID], at)
				}
				turn[e.AgentID] = at
			case "api_error":
				if e.ErrorClass == "429" {
					r.RateLimited++
				}
			}
		}
		if st.count > 0 {
			r.interrupts = append(r.interrupts, st)
		}
	}
	r.UnfinishedSubagents = unfinished(subagents, ended, now)
	r.Classes = classRows(classes)
	r.denials = denialRows(denials)
	for _, d := range r.denials[:min(len(r.denials), troubleTopRows)] {
		r.Denials = append(r.Denials, d.DenialRow)
	}
	slices.SortStableFunc(r.interrupts, func(a, b sessionTrouble) int {
		return cmp.Or(cmp.Compare(b.count, a.count), cmp.Compare(a.sid, b.sid))
	})
	for _, st := range r.interrupts[:min(len(r.interrupts), troubleTopRows)] {
		r.InterruptSessions = append(r.InterruptSessions, SessionCount{st.sid, st.count})
	}
	return r
}

// parseTS is ts as a time, zero when it does not parse.
func parseTS(ts string) time.Time {
	at, _ := time.Parse(time.RFC3339Nano, ts)
	return at
}

// since is the ms from start to end, 0 when either is unknown or end is first.
func since(start, end time.Time) int64 {
	if start.IsZero() || end.IsZero() {
		return 0
	}
	return max(end.Sub(start).Milliseconds(), 0)
}

func addClass(classes map[string]*classAgg, sid string, e agentlogdb.AgentReportEvent) {
	class := cmp.Or(e.ErrorClass, agentlog.ClassOther)
	c := classes[class]
	if c == nil {
		c = &classAgg{tools: map[string]int{}, sessions: map[string]int{}}
		classes[class] = c
	}
	c.ms += durMS(e)
	c.tools[e.Name]++
	c.sessions[sid]++
}

func addDenial(denials map[DenialRow]*denialAgg, sid string, e agentlogdb.AgentReportEvent) {
	k := DenialRow{Kind: e.ErrorClass, Tool: e.Name, Target: e.Target}
	d := denials[k]
	if d == nil {
		d = &denialAgg{DenialRow: k, verb: cmp.Or(verb(e), e.Name), sessions: map[string]int{}}
		denials[k] = d
	}
	d.Count++
	d.ms += durMS(e)
	d.sessions[sid]++
}

// unfinished counts the subagents of the measured sessions (ended: uuid →
// ended_at) that never finished.
func unfinished(subagents []agentlogdb.AgentSubagent, ended map[string]string, now time.Time) int {
	n := 0
	for _, a := range subagents {
		end, ok := ended[a.SessionUUID]
		switch {
		case !ok:
		case a.Finished != nil:
			if !*a.Finished {
				n++
			}
		default:
			if at, err := time.Parse(time.RFC3339Nano, end); err == nil && now.Sub(at) > UnfinishedAfter {
				n++
			}
		}
	}
	return n
}

// byCount orders keys by their count, the most first, then by key.
func byCount(m map[string]int) []string {
	return slices.SortedFunc(maps.Keys(m), func(a, b string) int { return cmp.Or(cmp.Compare(m[b], m[a]), cmp.Compare(a, b)) })
}

func classRows(classes map[string]*classAgg) []ErrorClassRow {
	out := []ErrorClassRow{}
	for class, c := range classes {
		row := ErrorClassRow{Class: class, Tool: byCount(c.tools)[0], Sessions: []SessionCount{}, ms: c.ms, nSessions: len(c.sessions)}
		for _, n := range c.tools {
			row.Count += n
		}
		for _, sid := range byCount(c.sessions)[:min(len(c.sessions), classSessions)] {
			row.Sessions = append(row.Sessions, SessionCount{sid, c.sessions[sid]})
		}
		out = append(out, row)
	}
	slices.SortFunc(out, func(a, b ErrorClassRow) int {
		return cmp.Or(cmp.Compare(b.Count, a.Count), cmp.Compare(a.Class, b.Class))
	})
	return out
}

func denialRows(denials map[DenialRow]*denialAgg) []denialAgg {
	out := []denialAgg{}
	for _, d := range denials {
		out = append(out, *d)
	}
	slices.SortFunc(out, func(a, b denialAgg) int {
		return cmp.Or(cmp.Compare(b.Count, a.Count), cmp.Compare(a.Kind, b.Kind), cmp.Compare(a.Tool, b.Tool), cmp.Compare(a.Target, b.Target))
	})
	return out
}

// t1Actions names T1's action per error class; a class not here (exit_code is
// H5's, other and the classes with no known fix) gets no hint.
var t1Actions = map[string]string{
	agentlog.ClassIsolation:      "t1.action.isolation",
	agentlog.ClassUnknownAgent:   "t1.action.definition",
	agentlog.ClassNoSuchTool:     "t1.action.definition",
	agentlog.ClassInputInvalid:   "t1.action.input",
	agentlog.ClassTooLarge:       "t1.action.large",
	agentlog.ClassEditNoMatch:    "t1.action.edit",
	agentlog.ClassEditMultiMatch: "t1.action.edit",
	agentlog.ClassSleepBlocked:   "t1.action.sleep",
	agentlog.ClassAgentLimit:     "t1.action.agents",
}

// T1: one hint per error class with a known fix and ClassMin+ failed calls;
// the estimate is the failed calls' time, the fix opens the session with the
// most of them.
func failedClasses(in HintInput) []Hint {
	l := in.Lang
	var out []Hint
	for _, c := range in.Trouble.Classes {
		action, ok := t1Actions[c.Class]
		if !ok || c.Count < ClassMin || len(c.Sessions) == 0 {
			continue
		}
		h := Hint{ID: "T1", EstimateMS: c.ms, Action: l.f(action), Fix: &Fix{Kind: FixOpenSession, Ref: c.Sessions[0].UUID},
			Finding: l.f("t1.finding", l.f("t1.class."+c.Class), l.count(c.Count, "time"), c.Tool,
				l.count(c.nSessions, "session.in"), l.dur(c.ms))}
		for _, s := range c.Sessions {
			h.Evidence = append(h.Evidence, sessionEv(s.UUID, l.count(s.Count, "failure")))
		}
		out = append(out, h)
	}
	return out
}

// T2: the commands denied DenialMin+ times by auto mode or a permission rule,
// in one hint whose fix copies their allow rules; the estimate is the denied
// calls' time.
func deniedCalls(in HintInput) []Hint {
	count := map[string]int{}
	var ms int64
	sessions := map[string]int{}
	for _, d := range in.Trouble.denials {
		if d.Kind == DenialAutoBlocked || d.Kind == DenialRule {
			count[d.verb] += d.Count
		}
	}
	verbs := slices.DeleteFunc(byCount(count), func(v string) bool { return count[v] < DenialMin })
	if len(verbs) == 0 {
		return nil
	}
	n := 0
	for _, d := range in.Trouble.denials {
		if (d.Kind == DenialAutoBlocked || d.Kind == DenialRule) && slices.Contains(verbs, d.verb) {
			n += d.Count
			ms += d.ms
			for sid, c := range d.sessions {
				sessions[sid] += c
			}
		}
	}
	l := in.Lang
	h := Hint{ID: "T2", EstimateMS: ms, Action: l.f("t2.action"), Fix: &Fix{Kind: FixCopyAllowRules},
		Finding: l.f("t2.finding", l.count(n, "call"), l.count(len(verbs), "command.of"), l.dur(ms), strings.Join(verbs, ", "))}
	for _, v := range verbs {
		h.Fix.Rules = append(h.Fix.Rules, allowRule(v))
		h.Evidence = append(h.Evidence, Evidence{Kind: "command", Ref: v, Label: l.count(count[v], "denial")})
	}
	for _, sid := range byCount(sessions) {
		h.Evidence = append(h.Evidence, sessionEv(sid, l.count(sessions[sid], "denial")))
	}
	return []Hint{h}
}

// T3: the sessions where the owner stopped or rejected the agent
// InterruptMin+ times, in one hint naming the worst first; the estimate is
// the stopped work's time.
func interrupted(in HintInput) []Hint {
	l := in.Lang
	h := Hint{ID: "T3", Action: l.f("t3.action")}
	total := 0
	for _, st := range in.Trouble.interrupts { // the most first
		if st.count < InterruptMin {
			continue
		}
		if h.Fix == nil {
			h.Fix = &Fix{Kind: FixOpenSession, Ref: st.sid}
		}
		total += st.count
		h.EstimateMS += st.ms
		h.Evidence = append(h.Evidence, sessionEv(st.sid, l.f("t3.label", l.count(st.count, "time"), l.dur(st.ms))))
	}
	if total == 0 {
		return nil
	}
	h.Finding = l.f("t3.finding", InterruptMin, l.count(len(h.Evidence), "session.in"), l.count(total, "time"), l.dur(h.EstimateMS))
	return []Hint{h}
}
