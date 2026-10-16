package agentreport

import (
	"cmp"
	"fmt"
	"maps"
	"slices"
	"strings"
	"time"

	"watchtower/internal/agentlog"
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
	evidenceMax       = 5               // command evidence items cited by H2
)

// Evidence is what a hint rests on: Kind is session, target or command and Ref
// the session uuid, "#<target id>" or the command verb.
type Evidence struct {
	Kind  string `json:"kind"`
	Ref   string `json:"ref"`
	Label string `json:"label"`
}

// Hint is one rule-based finding with its estimated saving in time or money.
type Hint struct {
	ID          string     `json:"id"`
	Finding     string     `json:"finding"`
	EstimateMS  int64      `json:"estimate_ms"`
	EstimateUSD float64    `json:"estimate_usd"`
	Evidence    []Evidence `json:"evidence"`
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
// as in Tasks.
type HintInput struct {
	Sessions map[string]SessionView
	Tasks    []TaskRow
	Targets  []db.AgentReportTarget
	Events   map[string][]db.AgentReportEvent
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
	slices.SortStableFunc(out, func(a, b Hint) int {
		return cmp.Or(cmp.Compare(b.EstimateMS, a.EstimateMS), cmp.Compare(b.EstimateUSD, a.EstimateUSD))
	})
	if out == nil {
		out = []Hint{}
	}
	return out
}

func durMS(e db.AgentReportEvent) int64 {
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
	now := in.Now.UTC()
	parents := map[int64]bool{}
	for _, t := range in.Targets {
		if t.ParentID != nil {
			parents[*t.ParentID] = true
		}
	}
	text := map[int64]string{}
	wins := map[int64][]window{}
	for _, t := range in.Targets {
		if !parents[t.ID] {
			text[t.ID] = t.Text
			wins[t.ID] = windows(t.History, now)
		}
	}
	type key struct{ scope, verb string }
	runs := map[key][]timedEvent{}
	inSessions := map[key]map[string]bool{}
	for _, sid := range sessions {
		evs := sortEvents(in.Events[sid], func(e db.AgentReportEvent) bool { return e.Kind == "tool" })
		linked := map[int64]bool{}
		for _, e := range evs {
			if id, ok := targetID(e.Target); ok && len(wins[id]) > 0 {
				linked[id] = true
			}
		}
		ids := slices.Sorted(maps.Keys(linked))
		for _, e := range evs {
			if ToolClass(e.Name, e.Target) != ClassBuildTest {
				continue
			}
			scope := sid
			var best time.Duration = -1
			for _, id := range ids {
				for _, w := range wins[id] {
					if !w.has(e.at) {
						continue
					}
					if d := w.end.Sub(w.start); best < 0 || d < best {
						best, scope = d, fmt.Sprintf("#%d", id)
					}
				}
			}
			k := key{scope, verb(e.AgentReportEvent)}
			runs[k] = append(runs[k], e)
			if inSessions[k] == nil {
				inSessions[k] = map[string]bool{}
			}
			inSessions[k][sid] = true
		}
	}
	keys := slices.SortedFunc(maps.Keys(runs), func(a, b key) int {
		return cmp.Or(cmp.Compare(a.scope, b.scope), cmp.Compare(a.verb, b.verb))
	})
	var out []Hint
	for _, k := range keys {
		rs := runs[k]
		if len(rs) < RepeatRuns {
			continue
		}
		slices.SortStableFunc(rs, func(a, b timedEvent) int { return a.at.Compare(b.at) })
		var total int64
		for _, r := range rs {
			total += durMS(r.AgentReportEvent)
		}
		if total <= RepeatMin.Milliseconds() {
			continue
		}
		est := total - durMS(rs[0].AgentReportEvent)
		label := fmt.Sprintf("%d runs, %s", len(rs), fmtDur(total))
		h := Hint{ID: "H1", EstimateMS: est, Evidence: []Evidence{{Kind: "command", Ref: k.verb, Label: label}}}
		where := "session " + short(k.scope)
		if strings.HasPrefix(k.scope, "#") {
			where = "target " + k.scope
			id, _ := targetID(k.scope)
			h.Evidence = append(h.Evidence, Evidence{Kind: "target", Ref: k.scope, Label: text[id]})
		}
		for _, sid := range slices.Sorted(maps.Keys(inSessions[k])) {
			h.Evidence = append(h.Evidence, sessionEv(sid, short(sid)))
		}
		h.Finding = fmt.Sprintf("%s ran %d times in %s, %s in all; the runs after the first took %s",
			k.verb, len(rs), where, fmtDur(total), fmtDur(est))
		out = append(out, h)
	}
	return out
}

func isCheap(e db.AgentReportEvent) bool {
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
	h := Hint{ID: "H2", EstimateMS: (median - cheapBaseline.Milliseconds()) * int64(n)}
	for _, v := range verbs[:min(len(verbs), evidenceMax)] {
		h.Evidence = append(h.Evidence, Evidence{Kind: "command", Ref: v, Label: fmt.Sprintf("%d calls, %s", count[v], fmtDur(total[v]))})
	}
	h.Finding = fmt.Sprintf("%d read, search and git status/log/diff calls took a median of %s each, likely permission prompts; allow rules would help (/fewer-permission-prompts)",
		n, fmtSec(median))
	return []Hint{h}
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
		out = append(out, Hint{ID: "H3", EstimateMS: est,
			Finding: fmt.Sprintf("Session %s ran %d foreground subagents one after another (%.1f at once on average); in parallel they could save up to %s",
				short(sid), sv.Subagents.Foreground, sv.Subagents.AvgParallel, fmtDur(est)),
			Evidence: []Evidence{sessionEv(sid, fmt.Sprintf("%d subagents, %s", sv.Subagents.Foreground, fmtDur(sum)))}})
	}
	return out
}

func ownerOver(t TimeSplit) bool {
	return t.ActiveMS > 0 && float64(t.OwnerMS) > OwnerShareMax*float64(t.ActiveMS)
}

func ownerLabel(t TimeSplit) string {
	return fmt.Sprintf("%s waiting, %d%% of %s active", fmtDur(t.OwnerMS), t.OwnerMS*100/t.ActiveMS, fmtDur(t.ActiveMS))
}

// H4: waiting for you over OwnerShareMax of a session's or task's active
// time. One hint names them all; its estimate is the sessions' waiting time,
// or, when only tasks are over the line, the largest task's (task time is
// session time attributed, so the two are never added).
func ownerShare(in HintInput, sessions []string) []Hint {
	h := Hint{ID: "H4"}
	nSessions, nTasks := 0, 0
	for _, sid := range sessions {
		sv, ok := in.Sessions[sid]
		if !ok || !ownerOver(sv.Time) {
			continue
		}
		nSessions++
		h.EstimateMS += sv.Time.OwnerMS
		h.Evidence = append(h.Evidence, sessionEv(sid, ownerLabel(sv.Time)))
	}
	var largest int64
	for _, t := range in.Tasks {
		if !ownerOver(t.Time) {
			continue
		}
		nTasks++
		largest = max(largest, t.Time.OwnerMS)
		h.Evidence = append(h.Evidence, Evidence{Kind: "target", Ref: fmt.Sprintf("#%d", t.TargetID), Label: t.Text})
	}
	if len(h.Evidence) == 0 {
		return nil
	}
	if nSessions == 0 {
		h.EstimateMS = largest
	}
	var where []string
	if nSessions > 0 {
		where = append(where, plural(nSessions, "session"))
	}
	if nTasks > 0 {
		where = append(where, plural(nTasks, "task"))
	}
	h.Finding = fmt.Sprintf("Waiting for you took over %d%% of active time in %s, %s in all",
		int(OwnerShareMax*100), strings.Join(where, " and "), fmtDur(h.EstimateMS))
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
		for _, e := range sortEvents(in.Events[sid], func(e db.AgentReportEvent) bool { return e.Kind == "tool" }) {
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
			out = append(out, Hint{ID: "H5", EstimateMS: lost[v],
				Finding: fmt.Sprintf("%s failed %d times in a row in session %s, %s spent on the failed runs",
					v, failed[v], short(sid), fmtDur(lost[v])),
				Evidence: []Evidence{
					sessionEv(sid, short(sid)),
					{Kind: "command", Ref: v, Label: fmt.Sprintf("%d failures in a row", failed[v])},
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
		var why []string
		if sv.CacheReadShare < CacheShareMin && sv.CostUSD > CacheCostMin {
			why = append(why, fmt.Sprintf("a %d%% cache read share", int(sv.CacheReadShare*100)))
		}
		if sv.Compactions >= CompactionsMax {
			why = append(why, fmt.Sprintf("%d compactions", sv.Compactions))
		}
		if len(why) == 0 {
			continue
		}
		out = append(out, Hint{ID: "H6", EstimateUSD: sv.CostUSD,
			Finding:  fmt.Sprintf("Session %s cost %s with %s; its context was expensive", short(sid), fmtUSD(sv.CostUSD), strings.Join(why, " and ")),
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
	h := Hint{ID: "H7", EstimateUSD: subCost - repriced,
		Finding: fmt.Sprintf("Subagents on %s cost %s, %d%% of the period's %s; on %s they would cost about %s less",
			strings.Join(slices.Sorted(maps.Keys(models)), ", "), fmtUSD(subCost), int(subCost*100/spend), fmtUSD(spend), next, fmtUSD(subCost-repriced))}
	for _, sid := range slices.Sorted(maps.Keys(bySession)) {
		h.Evidence = append(h.Evidence, sessionEv(sid, fmtUSD(bySession[sid])+" on subagents"))
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

func plural(n int, noun string) string {
	if n == 1 {
		return "1 " + noun
	}
	return fmt.Sprintf("%d %ss", n, noun)
}

func fmtUSD(v float64) string { return fmt.Sprintf("$%.2f", v) }
