package agentreport

import (
	"bytes"
	"cmp"
	"io"
	"io/fs"
	"maps"
	"math"
	"os"
	"path/filepath"
	"slices"

	"watchtower/internal/agentlogdb"
)

const (
	// RepeatReadsMin is how often one file must be read in one session to
	// count as a repeated read.
	RepeatReadsMin = 3
	// outsideTarget is the one target the parser gives every file outside
	// the workbench folder (agentlog's relativeTarget): never a repeated file.
	outsideTarget = "<outside>"
	// defaultBytesPerToken converts bytes to tokens in a lane with no
	// baseline parts to measure its own ratio.
	defaultBytesPerToken = 2.6
	contextTopRows       = 10 // rows of top_sources and repeated_reads
)

// Growth sources that are not a tool.
const (
	GrowthModel     = "model"     // the previous call's output, thinking excluded
	GrowthOwner     = "owner"     // an owner turn and what came with it
	GrowthReminders = "reminders" // attachments and reminders of unknown size
)

// ContextReport is where the period's context went: what every session start
// costs, what made it grow, the biggest sources, files read again and again,
// compactions and the sizes on disk now. Only the sessions with the v2 facts
// (FactsSessions of Sessions) are measured.
type ContextReport struct {
	Lead             string          `json:"lead"` // one plain sentence; "" without v2 facts
	FactsSessions    int             `json:"facts_sessions"`
	Sessions         int             `json:"sessions"`
	Baseline         BaselineSplit   `json:"baseline"`
	SubagentBaseline BaselineSplit   `json:"subagent_baseline"`
	Growth           []GrowthRow     `json:"growth"`
	TopSources       []SourceRow     `json:"top_sources"`
	RepeatedReads    []RepeatRow     `json:"repeated_reads"`
	Compactions      CompactionStats `json:"compactions"`
	Disk             DiskSizes       `json:"disk"`
}

// BaselineSplit is what a lane's context held before its first API call:
// Tokens is the median over the lanes, Parts its split by part (shares over
// every lane's bytes), largest first.
type BaselineSplit struct {
	Tokens int64       `json:"tokens"`
	Parts  []PartShare `json:"parts"`

	lanes    int      // lanes measured
	sessions []string // their sessions, the most instructions first (C1's evidence)
}

// PartShare is one baseline part: instructions, skills, agents, mcp,
// deferred_tools, hooks, other, system or tools.
type PartShare struct {
	Part   string  `json:"part"`
	Tokens int64   `json:"tokens"`
	Share  float64 `json:"share"`
}

// GrowthRow is the context growth one source caused: a tool name, or
// GrowthModel, GrowthOwner, GrowthReminders.
type GrowthRow struct {
	Source string  `json:"source"`
	Tokens int64   `json:"tokens"`
	Share  float64 `json:"share"`
}

// SourceRow is the growth of one tool and target (a shell verb, a path).
type SourceRow struct {
	Tool     string `json:"tool"`
	Target   string `json:"target"`
	Tokens   int64  `json:"tokens"`
	Calls    int    `json:"calls"`
	Sessions int    `json:"sessions"`

	sessions []string // in the order the period lists them (C2's evidence)
}

// RepeatRow is a file read RepeatReadsMin+ times in a session with no edit
// of it in between: Reads and Session are the worst run's, Tokens what the
// reads after the first added in every such run. Paged reads (offset/limit)
// of one file count as repeats: the read range is not stored.
type RepeatRow struct {
	Target  string `json:"target"`
	Reads   int    `json:"reads"`
	Session string `json:"session_uuid"`
	Tokens  int64  `json:"tokens"`

	sessions []sessionTokens // the repeat tokens per session, in period order (C3's evidence)
}

type sessionTokens struct {
	sid    string
	tokens int64
}

// CompactionStats counts the compactions; the medians cover those whose
// sizes were measured.
type CompactionStats struct {
	Count            int   `json:"count"`
	MedianPreTokens  int64 `json:"median_pre_tokens"`
	MedianPostTokens int64 `json:"median_post_tokens"`
	Sessions         int   `json:"sessions"`
}

// DiskSizes are the workbench folder's instruction files as they are now.
type DiskSizes struct {
	ClaudeMDBytes int64 `json:"claude_md_bytes"`
	ClaudeMDLines int   `json:"claude_md_lines"`
	RulesBytes    int64 `json:"rules_bytes"` // .claude/rules/**
}

func ctxTokens(e agentlogdb.AgentReportEvent) int64 {
	return e.InputTokens + e.CacheReadTokens + e.CacheWrite5mTokens + e.CacheWrite1hTokens
}

// laneParts is one lane's baseline parts.
type laneParts struct {
	agent string
	bytes int64
	parts []agentlogdb.AgentContextPart
}

// gapItem is a tool result that entered the context between two calls.
type gapItem struct {
	name   string
	bytes  int64 // -1 = not measured
	tokens int64 // its share of the growth, set by attribute
	src    int   // index into contextAcc.srcs
	read   int   // index into contextAcc.reads, -1 = not a repeated read
}

type laneState struct {
	prev     agentlogdb.AgentReportEvent
	seen     bool // prev is set
	perToken float64
	owner    bool // an owner turn since prev
	gap      []gapItem
}

type srcKey struct{ tool, target string }

type srcAgg struct {
	SourceRow
	last string // the last session counted
}

// readAgg is one run of reads of a file: an edit of the file starts a new run.
type readAgg struct {
	target string
	n      int
	tokens int64 // of the reads after the first
}

type baseAgg struct {
	totals   []int64
	parts    map[string]float64
	sessions []string
	instr    map[string]float64
}

type contextAcc struct {
	growth   map[string]int64
	srcIdx   map[srcKey]int
	srcs     []srcAgg
	readIdx  map[string]int // this session's current run per file
	reads    []readAgg      // this session's runs
	repeats  map[string]*RepeatRow
	main     baseAgg
	sub      baseAgg
	pre      []int64
	post     []int64
	comp     CompactionStats
	partsFor map[string][]laneParts
}

// Context measures the period's context from the sessions' events (keyed by
// uuid, in AgentReportEvents order), their baseline parts and the workbench
// folder ("" = no disk sizes). Sessions without the v2 facts are skipped.
//
// Growth, per lane: between two calls the context grew by Δ = ctx(n) −
// ctx(n−1) (a Δ ≤ 0 is a clear and skipped); the previous call's output minus
// its thinking explains up to Δ (model); the rest goes to the tool results in
// between by their bytes converted at the lane's tokens per byte — split in
// proportion when they explain all of it, else each takes its own size and
// what is left is the owner's turn when one came in between, else reminders.
func Context(sessions []agentlogdb.AgentReportSession, events map[string][]agentlogdb.AgentReportEvent,
	parts []agentlogdb.AgentContextPart, folder string) ContextReport {
	r := ContextReport{Sessions: len(sessions), Growth: []GrowthRow{}, TopSources: []SourceRow{}, RepeatedReads: []RepeatRow{},
		Baseline: BaselineSplit{Parts: []PartShare{}}, SubagentBaseline: BaselineSplit{Parts: []PartShare{}}, Disk: diskSizes(folder)}
	a := &contextAcc{growth: map[string]int64{}, srcIdx: map[srcKey]int{}, readIdx: map[string]int{}, repeats: map[string]*RepeatRow{},
		main: newBaseAgg(), sub: newBaseAgg(), partsFor: groupParts(parts)}
	for _, s := range sessions {
		if !s.Facts {
			continue
		}
		r.FactsSessions++
		a.session(s.SessionUUID, events[s.SessionUUID])
	}
	r.Baseline, r.SubagentBaseline = a.main.split(), a.sub.split()
	r.Growth = growthRows(a.growth)
	r.TopSources = topSources(a.srcs)
	r.RepeatedReads = repeatRows(a.repeats)
	a.comp.MedianPreTokens, a.comp.MedianPostTokens = median(a.pre), median(a.post)
	r.Compactions = a.comp
	return r
}

func newBaseAgg() baseAgg { return baseAgg{parts: map[string]float64{}, instr: map[string]float64{}} }

// groupParts groups the parts (ordered by session, agent id) by session and lane.
func groupParts(parts []agentlogdb.AgentContextPart) map[string][]laneParts {
	out := map[string][]laneParts{}
	for i := 0; i < len(parts); {
		j := i
		lp := laneParts{agent: parts[i].AgentID}
		for j < len(parts) && parts[j].SessionUUID == parts[i].SessionUUID && parts[j].AgentID == parts[i].AgentID {
			lp.bytes += max(parts[j].Bytes, 0)
			j++
		}
		lp.parts = parts[i:j]
		out[parts[i].SessionUUID] = append(out[parts[i].SessionUUID], lp)
		i = j
	}
	return out
}

func (a *contextAcc) session(sid string, evs []agentlogdb.AgentReportEvent) {
	clear(a.readIdx)
	a.reads = a.reads[:0]
	lanes := map[string]*laneState{}
	firstCtx := map[string]int64{}
	compacted := false
	for _, e := range evs {
		ls := lanes[e.AgentID]
		if ls == nil {
			ls = &laneState{}
			lanes[e.AgentID] = ls
		}
		switch e.Kind {
		case "api_call":
			if !ls.seen {
				firstCtx[e.AgentID] = ctxTokens(e)
				ls.perToken = tokensPerByte(a.partsFor[sid], e.AgentID, ctxTokens(e))
			} else {
				a.attribute(ls, ctxTokens(e)-ctxTokens(ls.prev), max(ls.prev.OutputTokens-ls.prev.ThinkingTokens, 0))
			}
			ls.prev, ls.seen, ls.owner, ls.gap = e, true, false, ls.gap[:0]
		case "tool":
			it := a.tool(sid, e)
			if ls.seen {
				ls.gap = append(ls.gap, it)
			}
		case "owner_turn":
			if e.Trigger == "owner" || e.Trigger == "" {
				ls.owner = true
			}
		case "compaction":
			a.comp.Count++
			compacted = true
			if e.PreTokens != nil {
				a.pre = append(a.pre, *e.PreTokens)
			}
			if e.PostTokens != nil {
				a.post = append(a.post, *e.PostTokens)
			}
		}
	}
	if compacted {
		a.comp.Sessions++
	}
	for _, lp := range a.partsFor[sid] {
		total, ok := firstCtx[lp.agent]
		if !ok || total <= 0 {
			total = int64(math.Round(float64(lp.bytes) / defaultBytesPerToken))
		}
		agg := &a.main
		if lp.agent != "" {
			agg = &a.sub
		}
		agg.add(sid, lp, total)
	}
	for _, rd := range a.reads {
		if rd.n < RepeatReadsMin {
			continue
		}
		row := a.repeats[rd.target]
		if row == nil {
			row = &RepeatRow{Target: rd.target}
			a.repeats[rd.target] = row
		}
		row.Tokens += rd.tokens
		if n := len(row.sessions); n > 0 && row.sessions[n-1].sid == sid {
			row.sessions[n-1].tokens += rd.tokens
		} else {
			row.sessions = append(row.sessions, sessionTokens{sid, rd.tokens})
		}
		if rd.n > row.Reads {
			row.Reads, row.Session = rd.n, sid
		}
	}
}

// tokensPerByte is a lane's tokens per byte: its first call's context over
// its baseline parts' bytes (lps = the session's lanes), else 1 /
// defaultBytesPerToken.
func tokensPerByte(lps []laneParts, agent string, first int64) float64 {
	for _, lp := range lps {
		if lp.agent == agent && lp.bytes > 0 && first > 0 {
			return float64(first) / float64(lp.bytes)
		}
	}
	return 1 / defaultBytesPerToken
}

// tool counts one tool call in its source and, for a Read, in the session's
// current run of reads of the file; an edit of the file ends that run (a
// read after an edit is a check, not a repeat).
func (a *contextAcc) tool(sid string, e agentlogdb.AgentReportEvent) gapItem {
	k := srcKey{e.Name, e.Target}
	i, ok := a.srcIdx[k]
	if !ok {
		i = len(a.srcs)
		a.srcIdx[k] = i
		a.srcs = append(a.srcs, srcAgg{SourceRow: SourceRow{Tool: e.Name, Target: e.Target}})
	}
	s := &a.srcs[i]
	s.Calls++
	if s.last != sid {
		s.last = sid
		s.Sessions++
		s.sessions = append(s.sessions, sid)
	}
	it := gapItem{name: e.Name, bytes: -1, src: i, read: -1}
	if e.ResultBytes != nil {
		it.bytes = max(*e.ResultBytes, 0)
	}
	if isFileEdit(e.Name) {
		delete(a.readIdx, e.Target)
	}
	if e.Name == "Read" && e.Target != "" && e.Target != outsideTarget {
		j, ok := a.readIdx[e.Target]
		if !ok {
			j = len(a.reads)
			a.readIdx[e.Target] = j
			a.reads = append(a.reads, readAgg{target: e.Target})
		}
		a.reads[j].n++
		if a.reads[j].n > 1 {
			it.read = j
		}
	}
	return it
}

func isFileEdit(tool string) bool {
	switch tool {
	case "Edit", "Write", "MultiEdit", "NotebookEdit":
		return true
	}
	return false
}

// attribute splits one growth delta of a lane (see Context).
func (a *contextAcc) attribute(ls *laneState, delta, prevOut int64) {
	if delta <= 0 {
		return
	}
	model := min(delta, prevOut)
	a.growth[GrowthModel] += model
	rest := delta - model
	if rest == 0 {
		return
	}
	var size, measured int64
	largest := -1
	for k := range ls.gap {
		it := &ls.gap[k]
		if it.bytes <= 0 {
			continue
		}
		size += it.bytes
		it.tokens = int64(math.Round(float64(it.bytes) * ls.perToken))
		measured += it.tokens
		if largest < 0 || it.bytes > ls.gap[largest].bytes {
			largest = k
		}
	}
	given := measured
	if measured >= rest && largest >= 0 {
		given = 0
		for k := range ls.gap {
			if it := &ls.gap[k]; it.bytes > 0 {
				it.tokens = rest * it.bytes / size
				given += it.tokens
			}
		}
		ls.gap[largest].tokens += rest - given // the rounding remainder
		given = rest
	}
	for _, it := range ls.gap {
		if it.bytes <= 0 || it.tokens <= 0 {
			continue
		}
		a.growth[it.name] += it.tokens
		a.srcs[it.src].Tokens += it.tokens
		if it.read >= 0 {
			a.reads[it.read].tokens += it.tokens
		}
	}
	if left := rest - given; left > 0 {
		if ls.owner {
			a.growth[GrowthOwner] += left
		} else {
			a.growth[GrowthReminders] += left
		}
	}
}

// add counts one lane's baseline: its parts scaled to total tokens.
func (b *baseAgg) add(sid string, lp laneParts, total int64) {
	b.totals = append(b.totals, total)
	if n := len(b.sessions); n == 0 || b.sessions[n-1] != sid { // a session's lanes come together
		b.sessions = append(b.sessions, sid)
	}
	if lp.bytes <= 0 {
		return
	}
	for _, p := range lp.parts {
		t := float64(max(p.Bytes, 0)) * float64(total) / float64(lp.bytes)
		b.parts[p.Part] += t
		if p.Part == "instructions" {
			b.instr[sid] += t
		}
	}
}

func (b *baseAgg) split() BaselineSplit {
	out := BaselineSplit{Parts: []PartShare{}, Tokens: median(b.totals), lanes: len(b.totals)}
	var sum float64
	for _, p := range slices.Sorted(maps.Keys(b.parts)) { // a fixed order: the float sum is the same every run
		sum += b.parts[p]
	}
	if sum > 0 {
		for p, t := range b.parts {
			share := t / sum
			out.Parts = append(out.Parts, PartShare{Part: p, Share: share, Tokens: int64(math.Round(share * float64(out.Tokens)))})
		}
	}
	slices.SortFunc(out.Parts, func(x, y PartShare) int {
		return cmp.Or(cmp.Compare(y.Share, x.Share), cmp.Compare(x.Part, y.Part))
	})
	out.sessions = slices.Clone(b.sessions)
	slices.SortStableFunc(out.sessions, func(x, y string) int { return cmp.Compare(b.instr[y], b.instr[x]) })
	return out
}

func growthRows(g map[string]int64) []GrowthRow {
	var total int64
	for _, t := range g {
		total += t
	}
	out := []GrowthRow{}
	for src, t := range g {
		if t > 0 {
			out = append(out, GrowthRow{Source: src, Tokens: t, Share: float64(t) / float64(total)})
		}
	}
	slices.SortFunc(out, func(x, y GrowthRow) int {
		return cmp.Or(cmp.Compare(y.Tokens, x.Tokens), cmp.Compare(x.Source, y.Source))
	})
	return out
}

func topSources(srcs []srcAgg) []SourceRow {
	out := []SourceRow{}
	for _, s := range srcs {
		if s.Tokens > 0 {
			out = append(out, s.SourceRow)
		}
	}
	slices.SortFunc(out, func(x, y SourceRow) int {
		return cmp.Or(cmp.Compare(y.Tokens, x.Tokens), cmp.Compare(y.Calls, x.Calls), cmp.Compare(x.Tool, y.Tool), cmp.Compare(x.Target, y.Target))
	})
	return out[:min(len(out), contextTopRows)]
}

func repeatRows(m map[string]*RepeatRow) []RepeatRow {
	out := []RepeatRow{}
	for _, r := range m {
		out = append(out, *r)
	}
	slices.SortFunc(out, func(x, y RepeatRow) int {
		return cmp.Or(cmp.Compare(y.Tokens, x.Tokens), cmp.Compare(y.Reads, x.Reads), cmp.Compare(x.Target, y.Target))
	})
	return out[:min(len(out), contextTopRows)]
}

// median of vs (the mean of the middle two for an even count), 0 for none.
func median(vs []int64) int64 {
	if len(vs) == 0 {
		return 0
	}
	s := slices.Clone(vs)
	slices.Sort(s)
	n := len(s)
	if n%2 == 1 {
		return s[n/2]
	}
	return (s[n/2-1] + s[n/2]) / 2
}

// claudeMDReadCap bounds the bytes of CLAUDE.md read to count its lines.
const claudeMDReadCap = 1 << 20

// claudeMDSize is the size and line count of a CLAUDE.md: a regular file only
// (a symlink to one, such as AGENTS.md, is followed; a FIFO or device is never
// opened), with the lines counted over its first claudeMDReadCap bytes.
func claudeMDSize(path string) (int64, int) {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return 0, 0
	}
	f, err := os.Open(path)
	if err != nil {
		return 0, 0
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, claudeMDReadCap))
	if err != nil {
		return 0, 0
	}
	lines := bytes.Count(b, []byte{'\n'})
	if len(b) > 0 && b[len(b)-1] != '\n' {
		lines++
	}
	return info.Size(), lines
}

// diskSizes reads the folder's CLAUDE.md (size, lines) and the total size of
// the regular files under .claude/rules; symlinks inside rules are skipped and
// anything missing reads as zero.
func diskSizes(folder string) DiskSizes {
	var d DiskSizes
	if folder == "" {
		return d
	}
	d.ClaudeMDBytes, d.ClaudeMDLines = claudeMDSize(filepath.Join(folder, "CLAUDE.md"))
	_ = filepath.WalkDir(filepath.Join(folder, ".claude", "rules"), func(_ string, e fs.DirEntry, err error) error {
		if err != nil || !e.Type().IsRegular() {
			return nil //nolint:nilerr // a missing or unreadable entry counts as zero, the walk goes on
		}
		if info, err := e.Info(); err == nil {
			d.RulesBytes += info.Size()
		}
		return nil
	})
	return d
}
