package agentreport

import (
	"cmp"
	"fmt"
	"maps"
	"slices"
	"strings"
	"time"

	"watchtower/internal/agentlog"
	"watchtower/internal/agentlogdb"
	"watchtower/internal/db"
)

// Hint thresholds (spec "Hints (rule-based)"); tune them here, not in the rules.
const (
	RepeatRuns        = 3               // H1: runs of one build & test verb in one target window or session
	RepeatMin         = 5 * time.Minute // H1: their total time must exceed this
	SlowCheapMedian   = 5 * time.Second // H2: median of cheap calls above this
	cheapBaseline     = 1 * time.Second // H2: what a cheap call should take
	SerialMinFG       = 3               // H3: foreground subagents in a session
	SerialMaxParallel = 1.3             // H3: average parallelism below this
	OwnerShareMax     = 0.30            // H4: waiting for you above this share of active time
	FailLoop          = 3               // H5: failures in a row of one verb
	CacheShareMin     = 0.50            // H6: cache read share below this ...
	CacheCostMin      = 5.0             // H6: ... with more than this spent ($)
	CompactionsMax    = 2               // H6: or this many compactions
	TopModelSubShare  = 0.30            // H7: subagents on the top model above this share of the spend
	evidenceMax       = 5               // evidence items a hint lists; the rest are counted in MoreEvidence
)

// Evidence is what a hint rests on: Kind is session, target or command and Ref
// the session uuid, "#<target id>" or the command verb.
type Evidence struct {
	Kind  string `json:"kind"`
	Ref   string `json:"ref"`
	Label string `json:"label"`
}

// Fix kinds: what the pane's button for a hint does.
const (
	FixCopyAllowRules = "copy_allow_rules" // copy Rules, permissions.allow lines
	FixOpenAsks       = "open_asks"        // open the Waiting for you stack
	FixOpenSession    = "open_session"     // open session Ref's analytics
)

// Fix is the one step the app can take for a hint.
type Fix struct {
	Kind  string   `json:"kind"`
	Ref   string   `json:"ref,omitempty"`
	Rules []string `json:"rules,omitempty"`
}

// Hint is one rule-based finding with its estimated saving in time or money,
// what to change (Action) and, where the app can take it, a Fix. Evidence is
// the largest evidenceMax items, MoreEvidence counts the rest.
type Hint struct {
	ID           string     `json:"id"`
	Finding      string     `json:"finding"`
	Action       string     `json:"action"`
	Fix          *Fix       `json:"fix,omitempty"`
	EstimateMS   int64      `json:"estimate_ms"`
	EstimateUSD  float64    `json:"estimate_usd"`
	Evidence     []Evidence `json:"evidence"`
	MoreEvidence int        `json:"more_evidence"`
}

// SessionView is what the hints read of one session.
type SessionView struct {
	UUID           string
	Time           TimeSplit
	Subagents      Subagents
	CostUSD        float64
	Compactions    int
	CacheReadShare float64
}

// HintInput is the period the hints judge; Events are keyed by session uuid.
// Targets (with their status history) and Now give H1 the targets' windows,
// as in Tasks. Lang is the language of the sentences.
type HintInput struct {
	Lang     Lang
	Sessions map[string]SessionView
	Tasks    []TaskRow
	Targets  []db.AgentReportTarget
	Events   map[string][]agentlogdb.AgentReportEvent
	Now      time.Time
}

// Hints runs the rules H1–H7 over the period and ranks what fired by the
// estimate, time first; a hint with no estimate is dropped.
func Hints(in HintInput) []Hint {
	sessions := slices.Sorted(maps.Keys(in.Sessions))
	for sid := range in.Events {
		if _, ok := in.Sessions[sid]; !ok {
			sessions = append(sessions, sid)
		}
	}
	slices.Sort(sessions)

	var all []Hint
	all = append(all, repeatedHeavy(in, sessions)...)
	all = append(all, slowCheap(in)...)
	all = append(all, serialSubagents(in, sessions)...)
	all = append(all, ownerShare(in, sessions)...)
	all = append(all, failingLoops(in, sessions)...)
	all = append(all, expensiveContext(in, sessions)...)
	all = append(all, topModelOnSubagents(in, sessions)...)

	out := slices.DeleteFunc(all, func(h Hint) bool { return h.EstimateMS <= 0 && h.EstimateUSD <= 0 })
	for i := range out {
		if n := len(out[i].Evidence); n > evidenceMax {
			out[i].Evidence, out[i].MoreEvidence = out[i].Evidence[:evidenceMax], n-evidenceMax
		}
	}
	slices.SortStableFunc(out, func(a, b Hint) int {
		return cmp.Or(cmp.Compare(b.EstimateMS, a.EstimateMS), cmp.Compare(b.EstimateUSD, a.EstimateUSD))
	})
	if out == nil {
		out = []Hint{}
	}
	return out
}

func durMS(e agentlogdb.AgentReportEvent) int64 {
	if e.DurationMS == nil {
		return 0
	}
	return max(*e.DurationMS, 0)
}

func sessionEv(sid, label string) Evidence { return Evidence{Kind: "session", Ref: sid, Label: label} }

func short(sid string) string { return sid[:min(len(sid), 8)] }

// H1: one build & test verb run RepeatRuns+ times inside one leaf target's
// in_progress/in_review window (from any session naming the target; the
// narrowest window holding a run wins) or, outside every window, in one session.
func repeatedHeavy(in HintInput, sessions []string) []Hint {
	text, wins := leafWindows(in.Targets, in.Now.UTC())
	runs := map[runKey][]timedEvent{}
	inSessions := map[runKey]map[string]bool{}
	for _, sid := range sessions {
		evs := sortEvents(in.Events[sid], func(e agentlogdb.AgentReportEvent) bool { return e.Kind == "tool" })
		ids := linkedLeaves(evs, wins)
		for _, e := range evs {
			if ToolClass(e.Name, e.Target) != ClassBuildTest {
				continue
			}
			k := runKey{runScope(e.at, sid, ids, wins), verb(e.AgentReportEvent)}
			runs[k] = append(runs[k], e)
			if inSessions[k] == nil {
				inSessions[k] = map[string]bool{}
			}
			inSessions[k][sid] = true
		}
	}
	keys := slices.SortedFunc(maps.Keys(runs), func(a, b runKey) int {
		return cmp.Or(cmp.Compare(a.scope, b.scope), cmp.Compare(a.verb, b.verb))
	})
	var out []Hint
	for _, k := range keys {
		if h, ok := repeatedHint(in.Lang, k, runs[k], inSessions[k], text); ok {
			out = append(out, h)
		}
	}
	return out
}

// runKey groups H1's runs: a "#<id>" target or a session id, and the verb.
type runKey struct{ scope, verb string }

// leafWindows are the leaf targets' texts and in_progress/in_review windows.
func leafWindows(targets []db.AgentReportTarget, now time.Time) (map[int64]string, map[int64][]window) {
	parents := map[int64]bool{}
	for _, t := range targets {
		if t.ParentID != nil {
			parents[*t.ParentID] = true
		}
	}
	text := map[int64]string{}
	wins := map[int64][]window{}
	for _, t := range targets {
		if !parents[t.ID] {
			text[t.ID] = t.Text
			wins[t.ID] = windows(t.History, now)
		}
	}
	return text, wins
}

// linkedLeaves are the leaf targets with a window that the session's tool
// calls name, sorted.
func linkedLeaves(evs []timedEvent, wins map[int64][]window) []int64 {
	linked := map[int64]bool{}
	for _, e := range evs {
		if id, ok := targetID(e.Target); ok && len(wins[id]) > 0 {
			linked[id] = true
		}
	}
	return slices.Sorted(maps.Keys(linked))
}

// runScope is "#<id>" of the narrowest linked window holding at, else sid.
func runScope(at time.Time, sid string, ids []int64, wins map[int64][]window) string {
	scope := sid
	var best time.Duration = -1
	for _, id := range ids {
		for _, w := range wins[id] {
			if !w.has(at) {
				continue
			}
			if d := w.end.Sub(w.start); best < 0 || d < best {
				best, scope = d, fmt.Sprintf("#%d", id)
			}
		}
	}
	return scope
}

// repeatedHint is H1 for one scope and verb, when it ran RepeatRuns+ times
// for more than RepeatMin in all.
func repeatedHint(l Lang, k runKey, rs []timedEvent, inSessions map[string]bool, text map[int64]string) (Hint, bool) {
	if len(rs) < RepeatRuns {
		return Hint{}, false
	}
	slices.SortStableFunc(rs, func(a, b timedEvent) int { return a.at.Compare(b.at) })
	var total int64
	for _, r := range rs {
		total += durMS(r.AgentReportEvent)
	}
	if total <= RepeatMin.Milliseconds() {
		return Hint{}, false
	}
	est := total - durMS(rs[0].AgentReportEvent)
	label := l.f("h1.label", l.count(len(rs), "run"), l.dur(total))
	h := Hint{ID: "H1", EstimateMS: est, Action: l.f("h1.action"), Evidence: []Evidence{{Kind: "command", Ref: k.verb, Label: label}}}
	where := l.f("h1.where.session", short(k.scope))
	if strings.HasPrefix(k.scope, "#") {
		where = l.f("h1.where.target", k.scope)
		id, _ := targetID(k.scope)
		h.Evidence = append(h.Evidence, Evidence{Kind: "target", Ref: k.scope, Label: text[id]})
	}
	for _, sid := range slices.Sorted(maps.Keys(inSessions)) {
		h.Evidence = append(h.Evidence, sessionEv(sid, short(sid)))
	}
	h.Finding = l.f("h1.finding", k.verb, l.count(len(rs), "time"), where, l.dur(total), l.dur(est))
	return h, true
}

func isCheap(e agentlogdb.AgentReportEvent) bool {
	if e.Name == "Bash" {
		switch e.Target {
		case "git status", "git log", "git diff":
			return true
		}
	}
	return ToolClass(e.Name, e.Target) == ClassReadSearch
}

// H2: the timed read & search and git status/log/diff calls of the period
// have a median above SlowCheapMedian.
func slowCheap(in HintInput) []Hint {
	var durs []int64
	count := map[string]int{}
	total := map[string]int64{}
	for _, evs := range in.Events {
		for _, e := range evs {
			if e.Kind != "tool" || e.DurationMS == nil || !isCheap(e) {
				continue
			}
			ms := durMS(e)
			durs = append(durs, ms)
			v := verb(e)
			count[v]++
			total[v] += ms
		}
	}
	if len(durs) == 0 {
		return nil
	}
	slices.Sort(durs)
	n := len(durs)
	median := durs[n/2]
	if n%2 == 0 {
		median = (durs[n/2-1] + durs[n/2]) / 2
	}
	if median <= SlowCheapMedian.Milliseconds() {
		return nil
	}
	verbs := slices.SortedFunc(maps.Keys(count), func(a, b string) int {
		return cmp.Or(cmp.Compare(count[b], count[a]), cmp.Compare(a, b))
	})
	l := in.Lang
	h := Hint{ID: "H2", EstimateMS: (median - cheapBaseline.Milliseconds()) * int64(n), Action: l.f("h2.action"),
		Fix: &Fix{Kind: FixCopyAllowRules}}
	for _, v := range verbs {
		h.Evidence = append(h.Evidence, Evidence{Kind: "command", Ref: v, Label: l.f("h2.label", l.count(count[v], "call"), l.dur(total[v]))})
		h.Fix.Rules = append(h.Fix.Rules, allowRule(v))
	}
	h.Finding = l.f("h2.finding", l.count(n, "call"), l.sec(median))
	return []Hint{h}
}

// allowRule is the permissions.allow line for a verb: a tool (Read,
// mcp__…) is its own name, a shell verb "Bash(<verb>:*)".
func allowRule(v string) string {
	if strings.HasPrefix(v, "mcp__") || (v != "" && v[0] >= 'A' && v[0] <= 'Z') {
		return v
	}
	return "Bash(" + v + ":*)"
}

// H3: a session with SerialMinFG+ foreground subagents running under
// SerialMaxParallel at once on average.
func serialSubagents(in HintInput, sessions []string) []Hint {
	var out []Hint
	for _, sid := range sessions {
		sv, ok := in.Sessions[sid]
		if !ok || sv.Subagents.Foreground < SerialMinFG || sv.Subagents.AvgParallel >= SerialMaxParallel {
			continue
		}
		var sum, longest int64
		for _, s := range subagentSpans(in.Events[sid]) {
			if s.background {
				continue
			}
			d := s.end.Sub(s.start).Milliseconds()
			sum += d
			longest = max(longest, d)
		}
		est := sum - longest
		l := in.Lang
		out = append(out, Hint{ID: "H3", EstimateMS: est, Action: l.f("h3.action"),
			Finding:  l.f("h3.finding", short(sid), l.count(sv.Subagents.Foreground, "fgsubagent"), sv.Subagents.AvgParallel, l.dur(est)),
			Evidence: []Evidence{sessionEv(sid, l.f("h3.label", l.count(sv.Subagents.Foreground, "subagent"), l.dur(sum)))}})
	}
	return out
}

func ownerOver(t TimeSplit) bool {
	return t.ActiveMS > 0 && float64(t.OwnerMS) > OwnerShareMax*float64(t.ActiveMS)
}

func ownerLabel(l Lang, t TimeSplit) string {
	return l.f("h4.label", l.dur(t.OwnerMS), t.OwnerMS*100/t.ActiveMS, l.dur(t.ActiveMS))
}

// H4: waiting for you over OwnerShareMax of a session's or task's active
// time. One hint names them all; its estimate is the sessions' waiting time,
// or, when only tasks are over the line, the largest task's (task time is
// session time attributed, so the two are never added).
func ownerShare(in HintInput, sessions []string) []Hint {
	l := in.Lang
	h := Hint{ID: "H4", Action: l.f("h4.action"), Fix: &Fix{Kind: FixOpenAsks}}
	type waited struct {
		ev Evidence
		ms int64
	}
	var all []waited
	nSessions, nTasks := 0, 0
	for _, sid := range sessions {
		sv, ok := in.Sessions[sid]
		if !ok || !ownerOver(sv.Time) {
			continue
		}
		nSessions++
		h.EstimateMS += sv.Time.OwnerMS
		all = append(all, waited{sessionEv(sid, ownerLabel(l, sv.Time)), sv.Time.OwnerMS})
	}
	var largest int64
	for _, t := range in.Tasks {
		if !ownerOver(t.Time) {
			continue
		}
		nTasks++
		largest = max(largest, t.Time.OwnerMS)
		all = append(all, waited{Evidence{Kind: "target", Ref: fmt.Sprintf("#%d", t.TargetID), Label: t.Text}, t.Time.OwnerMS})
	}
	if len(all) == 0 {
		return nil
	}
	// The longest waits first: the list is cut to evidenceMax.
	slices.SortStableFunc(all, func(a, b waited) int { return cmp.Compare(b.ms, a.ms) })
	for _, w := range all {
		h.Evidence = append(h.Evidence, w.ev)
	}
	if nSessions == 0 {
		h.EstimateMS = largest
	}
	var where []string
	if nSessions > 0 {
		where = append(where, l.count(nSessions, "session.in"))
	}
	if nTasks > 0 {
		where = append(where, l.count(nTasks, "task.in"))
	}
	h.Finding = l.f("h4.finding", int(OwnerShareMax*100), strings.Join(where, l.f("h4.and")), l.dur(h.EstimateMS))
	return []Hint{h}
}

// H5: one verb failing FailLoop+ times in a row in one agent lane of a
// session: a successful run of that verb breaks the streak, calls of other
// verbs in between do not.
func failingLoops(in HintInput, sessions []string) []Hint {
	type lane struct{ agent, verb string }
	var out []Hint
	for _, sid := range sessions {
		streak := map[lane][]int64{}
		lost := map[string]int64{}
		failed := map[string]int{}
		flush := func(l lane) {
			if len(streak[l]) >= FailLoop {
				failed[l.verb] += len(streak[l])
				for _, ms := range streak[l] {
					lost[l.verb] += ms
				}
			}
			delete(streak, l)
		}
		for _, e := range sortEvents(in.Events[sid], func(e agentlogdb.AgentReportEvent) bool { return e.Kind == "tool" }) {
			l := lane{e.AgentID, verb(e.AgentReportEvent)}
			if e.Outcome == "error" {
				streak[l] = append(streak[l], durMS(e.AgentReportEvent))
				continue
			}
			flush(l)
		}
		for l := range streak {
			flush(l)
		}
		for _, v := range slices.Sorted(maps.Keys(failed)) {
			l := in.Lang
			out = append(out, Hint{ID: "H5", EstimateMS: lost[v], Action: l.f("h5.action"),
				Fix:     &Fix{Kind: FixOpenSession, Ref: sid},
				Finding: l.f("h5.finding", v, l.count(failed[v], "time"), short(sid), l.dur(lost[v])),
				Evidence: []Evidence{
					sessionEv(sid, short(sid)),
					{Kind: "command", Ref: v, Label: l.f("h5.label", l.count(failed[v], "failure"))},
				}})
		}
	}
	return out
}

// H6: a session whose cache read share is under CacheShareMin with over
// CacheCostMin spent, or with CompactionsMax+ compactions.
func expensiveContext(in HintInput, sessions []string) []Hint {
	var out []Hint
	for _, sid := range sessions {
		sv, ok := in.Sessions[sid]
		if !ok {
			continue
		}
		l := in.Lang
		var why []string
		if sv.CacheReadShare < CacheShareMin && sv.CostUSD > CacheCostMin {
			why = append(why, l.f("h6.cache", int(sv.CacheReadShare*100)))
		}
		if sv.Compactions >= CompactionsMax {
			why = append(why, l.count(sv.Compactions, "compaction"))
		}
		if len(why) == 0 {
			continue
		}
		out = append(out, Hint{ID: "H6", EstimateUSD: sv.CostUSD, Action: l.f("h6.action"),
			Fix:      &Fix{Kind: FixOpenSession, Ref: sid},
			Finding:  l.f("h6.finding", short(sid), fmtUSD(sv.CostUSD), strings.Join(why, l.f("h6.and"))),
			Evidence: []Evidence{sessionEv(sid, fmtUSD(sv.CostUSD))}})
	}
	return out
}

// outputRate is a model's $ per million output tokens.
func outputRate(model string) float64 {
	usd, _ := agentlog.Cost(model, "", 0, 1e6, 0, 0, 0)
	return usd
}

// H7: subagent calls on the most expensive models of the price table cost
// over TopModelSubShare of the period's spend; the estimate re-prices their
// stored tokens at the next cheaper tier.
func topModelOnSubagents(in HintInput, sessions []string) []Hint {
	tiers := agentlog.ModelTiers()
	if len(tiers) == 0 {
		return nil
	}
	topRate := outputRate(tiers[0])
	next := ""
	for _, m := range tiers {
		if outputRate(m) < topRate {
			next = m
			break
		}
	}
	if next == "" {
		return nil
	}
	var spend, subCost, repriced float64
	bySession := map[string]float64{}
	models := map[string]bool{}
	for _, sid := range sessions {
		for _, e := range in.Events[sid] {
			if e.Kind != "api_call" {
				continue
			}
			spend += e.CostUSD
			if isMain(e) || outputRate(e.Model) != topRate {
				continue
			}
			alt, _ := agentlog.Cost(next, "", e.InputTokens, e.OutputTokens, e.CacheReadTokens, e.CacheWrite5mTokens, e.CacheWrite1hTokens)
			subCost += e.CostUSD
			repriced += alt
			bySession[sid] += e.CostUSD
			models[e.Model] = true
		}
	}
	if spend <= 0 || subCost <= TopModelSubShare*spend {
		return nil
	}
	l := in.Lang
	h := Hint{ID: "H7", EstimateUSD: subCost - repriced, Action: l.f("h7.action"),
		Finding: l.f("h7.finding", strings.Join(slices.Sorted(maps.Keys(models)), ", "), fmtUSD(subCost), int(subCost*100/spend),
			fmtUSD(spend), next, fmtUSD(subCost-repriced))}
	// The costliest sessions first: the list is cut to evidenceMax.
	for _, sid := range slices.SortedFunc(maps.Keys(bySession), func(a, b string) int {
		return cmp.Or(cmp.Compare(bySession[b], bySession[a]), cmp.Compare(a, b))
	}) {
		h.Evidence = append(h.Evidence, sessionEv(sid, l.f("h7.label", fmtUSD(bySession[sid]))))
	}
	return []Hint{h}
}

// fmtDur renders ms as "2h 10m", "7m 10s" or "45s".
func fmtDur(ms int64) string {
	d := time.Duration(ms) * time.Millisecond
	h, m, s := int(d.Hours()), int(d.Minutes())%60, int(d.Seconds())%60
	switch {
	case h > 0:
		return fmt.Sprintf("%dh %dm", h, m)
	case m > 0:
		return fmt.Sprintf("%dm %ds", m, s)
	}
	return fmt.Sprintf("%ds", s)
}

// fmtSec renders ms under a minute with one decimal ("7.5s"), else as fmtDur.
func fmtSec(ms int64) string {
	if ms < time.Minute.Milliseconds() {
		return fmt.Sprintf("%.1fs", float64(ms)/1000)
	}
	return fmtDur(ms)
}

func fmtUSD(v float64) string { return fmt.Sprintf("$%.2f", v) }
