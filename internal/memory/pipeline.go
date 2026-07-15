package memory

import (
	"context"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strings"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// extractSource is the WithSource tag that routes extractor calls to the
// cheap model tier (see internal/digest/models.go and internal/codex/models.go).
const extractSource = "memory.extract_episodes"

// seedWindowDays is the activity lookback for mechanical entity seeding
// (people/channels active in the last 30 days, per the design spec).
const seedWindowDays = 30

// mapOpenEpisodesCap bounds the "Recent open episodes" list in map.md.
const mapOpenEpisodesCap = 10

// RunStats counts what one consolidation run did.
type RunStats struct {
	OwnerEditsCommitted bool        // MEM-03: a dirty worktree was committed as owner-edit first
	Reconciled          Stats       // index mutations from the reconcile pass
	Seeded              int         // skeleton entity pages created
	Ingested            IngestStats // situation → episode mirror counts
	Messages            int         // raw messages loaded into extraction windows
	Windows             int         // channel windows built from those messages
	WindowsFailed       int         // windows whose extraction failed (watermark frozen for them)
	Episodes            int         // episode nodes written by the extractor
	RefsRejected        int         // provenance refs dropped by MEM-01 validation
	Malformed           int         // shape-degenerate extractor episodes (parsed but zero refs)
}

// Pipeline is the memory consolidation daemon phase: reconcile → seed →
// ingest → extract (chunked per channel window) → mechanical map.md render,
// with pipeline_runs/pipeline_steps accounting.
type Pipeline struct {
	db        *db.DB
	vault     *Vault
	generator digest.Generator
	cfg       config.MemoryConfig
	logf      func(string, ...any)
	// checkMsg is the MEM-01 provenance lookup — the database in production,
	// an erroring fake in tests exercising the lookup-failure freeze.
	checkMsg messageChecker
	// promptStore optionally serves user-customized templates for the
	// extractor prompt (same seam as the inbox pipeline); nil falls back to
	// the built-in default.
	promptStore *prompts.Store

	// Source labels the pipeline_runs row ("cli" or "daemon"). NewPipeline
	// defaults it to "cli"; the daemon overrides it.
	Source string
	// Language is the response language for extractor output, set from
	// cfg.Digest.Language at construction (cmd wiring). Empty falls back to
	// prompts.DefaultLanguage via prompts.Directive.
	Language string
}

// SetPromptStore sets an optional prompt store for loading customized prompts.
func (p *Pipeline) SetPromptStore(store *prompts.Store) {
	p.promptStore = store
}

// getPrompt loads a template from the prompt store, falling back to the
// built-in default (same shape as the inbox pipeline's seam).
func (p *Pipeline) getPrompt(id string) string {
	if p.promptStore != nil {
		if tmpl, _, err := p.promptStore.Get(id); err == nil {
			return tmpl
		}
	}
	return prompts.Defaults[id]
}

// NewPipeline creates a memory consolidation pipeline. generator may be nil
// (extraction is skipped); logf may be nil (logging is dropped).
func NewPipeline(database *db.DB, vault *Vault, gen digest.Generator, cfg config.MemoryConfig, logf func(string, ...any)) *Pipeline {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	return &Pipeline{db: database, vault: vault, generator: gen, cfg: cfg, logf: logf, checkMsg: database, Source: "cli"}
}

// Run executes one consolidation pass. Order per the design spec:
//
//  1. Owner edits committed first (MEM-03), then Reconcile so the index
//     absorbs the owner's changes before any machine write of this run.
//  2. Mechanical entity seeding.
//  3. Situations → episode nodes.
//  4. Episode extraction from raw text, chunked per channel window; the
//     watermark advances only behind fully committed windows (MEM-04).
//  5. Mechanical map.md render.
//  6. pipeline_runs finalization.
//
// Failure semantics: errors in steps 1–3 are fatal (the run stops, already
// committed work stays); a per-window AI failure in step 4 freezes the
// watermark for that window but never fails the run (window isolation,
// catchup-style) — it is recorded in the window's pipeline_steps row. A
// disabled config is a full no-op: nothing written, no pipeline_runs row.
func (p *Pipeline) Run(ctx context.Context) (RunStats, error) {
	var stats RunStats
	if !p.cfg.Enabled {
		return stats, nil
	}

	runID, err := p.db.CreatePipelineRun("memory", p.Source, "auto")
	if err != nil {
		p.logf("memory: create pipeline run: %v", err) // accounting only — the run proceeds unrecorded
	}
	acc := &usageAccumulator{}
	wmBefore, err := p.db.MemoryWatermark()
	if err != nil {
		return stats, p.fatal(runID, acc, &stats, wmBefore, err)
	}

	// (1) MEM-03: manual vault changes become their own owner-edit commit
	// before any machine write; Reconcile runs after so the index absorbs them.
	stats.OwnerEditsCommitted, err = p.vault.CommitOwnerEdits()
	if err != nil {
		return stats, p.fatal(runID, acc, &stats, wmBefore, fmt.Errorf("memory: owner edits: %w", err))
	}
	stats.Reconciled, err = Reconcile(p.vault, p.db)
	if err != nil {
		return stats, p.fatal(runID, acc, &stats, wmBefore, err)
	}

	// (2) Mechanical entity seeding (no AI).
	stats.Seeded, err = SeedEntities(p.vault, p.db, SeedConfig{MinMessages: p.cfg.SeedMinMessages, WindowDays: seedWindowDays})
	if err != nil {
		return stats, p.fatal(runID, acc, &stats, wmBefore, err)
	}

	// (3) Situations → episode nodes (mechanical).
	stats.Ingested, err = IngestSituations(p.vault, p.db, p.checkMsg, p.logf)
	if err != nil {
		return stats, p.fatal(runID, acc, &stats, wmBefore, err)
	}

	// (4) Episode extraction from raw text.
	if err := p.runExtract(ctx, runID, acc, &stats); err != nil {
		return stats, p.fatal(runID, acc, &stats, wmBefore, err)
	}

	// (5) Mechanical map.md render — non-fatal: the map is derived state and
	// is re-rendered on the next run.
	if err := p.renderMap(runID); err != nil {
		p.logf("memory: render map: %v", err)
	}

	wmAfter, err := p.db.MemoryWatermark()
	if err != nil {
		p.logf("memory: read watermark after run: %v", err)
		wmAfter = wmBefore
	}
	p.completeRun(runID, acc, stats.Episodes, wmBefore, wmAfter, nil)
	p.logf("memory: run done: seeded %d, ingested %+v, %d episodes from %d/%d windows (%d messages, %d refs rejected, %d malformed)",
		stats.Seeded, stats.Ingested, stats.Episodes, stats.Windows-stats.WindowsFailed, stats.Windows, stats.Messages, stats.RefsRejected, stats.Malformed)
	return stats, nil
}

// fatal finalizes the pipeline_runs row for a run-stopping error and returns
// that error for Run to propagate.
func (p *Pipeline) fatal(runID int64, acc *usageAccumulator, stats *RunStats, wm float64, err error) error {
	p.completeRun(runID, acc, stats.Episodes, wm, wm, err)
	return err
}

// usageAccumulator folds per-call digest.Usage values into run totals.
type usageAccumulator struct {
	input, output, totalAPI int
	model                   string
}

func (a *usageAccumulator) add(u *digest.Usage) {
	if u == nil {
		return
	}
	a.input += u.InputTokens
	a.output += u.OutputTokens
	a.totalAPI += u.TotalAPITokens
	if u.Model != "" {
		a.model = u.Model
	}
}

// completeRun finalizes the pipeline_runs row. The runs schema records cache
// reads and cache creation separately (migration 00017), but digest.Usage
// only exposes the combined API total, so the cache-side residual (total API
// tokens minus prompt tokens) is recorded under cache_read_tokens and
// cache_creation_tokens stays 0 until Usage grows the split.
func (p *Pipeline) completeRun(runID int64, acc *usageAccumulator, items int, pFrom, pTo float64, runErr error) {
	if runID == 0 {
		return
	}
	errMsg := ""
	if runErr != nil {
		errMsg = runErr.Error()
	}
	if err := p.db.CompletePipelineRun(runID, items, acc.input, acc.output, 0, acc.totalAPI, &pFrom, &pTo, errMsg); err != nil {
		p.logf("memory: complete pipeline run: %v", err)
		return
	}
	cacheRead := acc.totalAPI - acc.input
	if cacheRead < 0 {
		cacheRead = 0
	}
	model := acc.model
	if model == "" {
		model = "auto"
	}
	if _, err := p.db.Exec(`UPDATE pipeline_runs SET model = ?, cache_read_tokens = ? WHERE id = ?`,
		model, cacheRead, runID); err != nil {
		p.logf("memory: record run model/cache tokens: %v", err)
	}
}

// runWindow is one per-channel extraction window plus the ts_unix of each of
// its messages (parallel to Messages, ascending) for watermark math.
type runWindow struct {
	channelWindow
	tsUnix []float64
}

// runExtract is consolidation step 4: load raw messages above the watermark
// (capped at MaxChunkMessages — the rest stays as debt for the next run),
// group them into per-channel windows, and extract episodes window by window.
//
// v1 simplifications (Phase 3 territory, deliberate):
//   - windows already covered by a situation episode are NOT skipped —
//     extraction dedupe against situation coverage is left to Phase 3;
//   - channelWindow.RunningSummary is left empty (the digests table stores it
//     as a JSON blob, not the one-liner the prompt wants).
//
// Only a message-load failure is returned; per-window failures freeze the
// watermark (MEM-04, see safeWatermark) and are noted in the window's
// pipeline_steps row while the run continues with the next channel.
func (p *Pipeline) runExtract(ctx context.Context, runID int64, acc *usageAccumulator, stats *RunStats) error {
	if p.generator == nil {
		p.logf("memory: no generator configured, skipping episode extraction")
		return nil
	}
	wm, err := p.db.MemoryWatermark()
	if err != nil {
		return err
	}
	msgs, err := p.db.ListMemoryExtractMessages(wm, p.cfg.MaxChunkMessages)
	if err != nil {
		return err
	}
	if len(msgs) == 0 {
		return nil
	}

	windows := buildWindows(msgs, p.cfg.MaxWindowMessages)
	stats.Messages = len(msgs)
	stats.Windows = len(windows)
	done := make([]bool, len(windows))
	current := wm
	for i := range windows {
		if ctx.Err() != nil {
			p.logf("memory: extraction interrupted, %d windows left for the next run", len(windows)-i)
			break
		}
		w := windows[i]
		start := time.Now()
		episodes, rejected, malformed, usage, werr := p.extractWindow(ctx, runID, w)
		acc.add(usage)
		stats.Malformed += malformed
		status := "done"
		if werr != nil {
			// Window isolation: the failure freezes the watermark at the last
			// safe point, but the run continues with the next channel. This
			// window's messages stay above the watermark and are re-extracted
			// next run.
			status = "error"
			stats.WindowsFailed++
			p.logf("memory: extract #%s: %v", w.ChannelName, werr)
		} else {
			done[i] = true
			stats.Episodes += episodes
			stats.RefsRejected += rejected
			// MEM-04: the watermark moves only after this window's vault
			// commit succeeded, and never past a message that belongs to a
			// failed or still-pending window.
			if safe, ok := safeWatermark(windows, done); ok && safe > current {
				if err := p.db.SetMemoryWatermark(safe); err != nil {
					p.logf("memory: set watermark: %v", err)
				} else {
					current = safe
				}
			}
		}
		if runID != 0 {
			var u digest.Usage
			if usage != nil {
				u = *usage
			}
			pFrom, pTo := w.tsUnix[0], w.tsUnix[len(w.tsUnix)-1]
			if err := p.db.InsertPipelineStep(db.PipelineStep{
				RunID: runID, Step: i + 1, Total: len(windows), Status: status,
				ChannelID: w.ChannelID, ChannelName: w.ChannelName,
				InputTokens: u.InputTokens, OutputTokens: u.OutputTokens, TotalAPITokens: u.TotalAPITokens,
				MessageCount: len(w.Messages), PeriodFrom: &pFrom, PeriodTo: &pTo,
				DurationSeconds: time.Since(start).Seconds(),
			}); err != nil {
				p.logf("memory: record pipeline step: %v", err)
			}
		}
	}
	return nil
}

// buildWindows groups the (globally ts-ordered) messages into per-channel
// windows, then orders the windows by their last message ts so the watermark
// can trail completed windows (see safeWatermark).
//
// maxPerWindow bounds one window's message count (memory.max_window_messages)
// so a single busy channel cannot form one giant prompt that blows the model
// context and permanently fails as a poison window: a channel with more
// messages forms multiple sequential windows in the same run. safeWatermark
// stays correct across them — a later window of the channel starts at or
// after the earlier one's last ts, so an earlier failed window's first ts
// lower-bounds the freeze and later successes can never advance past it.
// maxPerWindow <= 0 means unbounded (used by tests only; config defaults it).
func buildWindows(msgs []db.MemoryExtractMessage, maxPerWindow int) []runWindow {
	index := make(map[string]int)
	var windows []runWindow
	for _, m := range msgs {
		i, ok := index[m.ChannelID]
		if ok && maxPerWindow > 0 && len(windows[i].Messages) >= maxPerWindow {
			ok = false // window full — start the channel's next sequential window
		}
		if !ok {
			i = len(windows)
			index[m.ChannelID] = i
			windows = append(windows, runWindow{channelWindow: channelWindow{ChannelID: m.ChannelID, ChannelName: m.ChannelName}})
		}
		windows[i].Messages = append(windows[i].Messages, extractMsg{TS: m.TS, Author: m.Author, Text: m.Text})
		windows[i].tsUnix = append(windows[i].tsUnix, m.TSUnix)
	}
	// Stable: same-channel windows keep their chronological order even when
	// last-ts ties (e.g. a same-second split).
	sort.SliceStable(windows, func(a, b int) bool {
		return windows[a].tsUnix[len(windows[a].tsUnix)-1] < windows[b].tsUnix[len(windows[b].tsUnix)-1]
	})
	return windows
}

// safeWatermark returns the highest message ts the watermark may advance to:
// every loaded message at or below it belongs to a successfully committed
// window, so advancing there never skips an unprocessed message even when
// windows overlap in time (MEM-04 freeze discipline, same spirit as
// INBOX-09). ok is false when no advance is possible.
func safeWatermark(windows []runWindow, done []bool) (ts float64, ok bool) {
	// bound = the smallest ts still owned by a failed or pending window; the
	// watermark must stay strictly below it.
	bound := math.Inf(1)
	for i, w := range windows {
		if !done[i] && w.tsUnix[0] < bound {
			bound = w.tsUnix[0]
		}
	}
	best := math.Inf(-1)
	for i, w := range windows {
		if !done[i] {
			continue
		}
		for j := len(w.tsUnix) - 1; j >= 0; j-- {
			if w.tsUnix[j] < bound {
				if w.tsUnix[j] > best {
					best = w.tsUnix[j]
					ok = true
				}
				break
			}
		}
	}
	return best, ok
}

// extractWindow runs the memory.extract_episodes call for one channel window
// and commits the resulting episode nodes (plus back-links on hinted entity
// pages) as one vault commit. Returns episodes written, MEM-01-rejected ref
// count, and shape-degenerate (zero-ref) episode count. Any error means the
// window was NOT committed.
func (p *Pipeline) extractWindow(ctx context.Context, runID int64, w runWindow) (episodes, rejected, malformed int, usage *digest.Usage, err error) {
	system, user := buildExtractPrompt(p.getPrompt(prompts.MemoryExtractEpisodes), p.Language, w.channelWindow, p.cfg.MaxEpisodesPerWindow)
	raw, usage, _, err := p.generator.Generate(digest.WithSource(ctx, extractSource), system, user, "")
	if err != nil {
		return 0, 0, 0, usage, fmt.Errorf("generate: %w", err)
	}
	eps, err := parseExtract(raw)
	if err != nil {
		return 0, 0, 0, usage, err
	}
	if p.cfg.MaxEpisodesPerWindow > 0 && len(eps) > p.cfg.MaxEpisodesPerWindow {
		eps = eps[:p.cfg.MaxEpisodesPerWindow]
	}
	// Success must key off affirmative shape: a reply whose episodes ALL
	// lack refs is a schema-degenerate answer (misnamed key, wrong nesting),
	// not routine chatter — fail the window so the watermark freezes exactly
	// like on an AI error. A genuinely empty [] stays a clean no-episode
	// window.
	valid, malformed := splitMalformed(eps)
	if malformed > 0 && len(valid) == 0 {
		return 0, 0, malformed, usage, fmt.Errorf("memory: extract returned %d episode(s), all without refs — schema-degenerate reply", malformed)
	}
	kept, rejected, err := validateRefs(p.checkMsg, valid)
	if err != nil {
		// Lookup failure, not an invalid ref: the check could not run, so
		// the window fails and is re-extracted next run (MEM-01/MEM-04).
		return 0, 0, malformed, usage, err
	}
	if rejected > 0 {
		p.logf("memory: extract #%s: refs_rejected=%d (MEM-01)", w.ChannelName, rejected)
	}
	if len(kept) == 0 {
		return 0, rejected, malformed, usage, nil // routine chatter — still a fully processed window
	}

	var nodes []Node
	var ids []string
	entityIdx := make(map[string]int) // entity node ID → index in nodes
	for _, ep := range kept {
		title := strings.Join(strings.Fields(ep.Title), " ")
		if title == "" {
			title = "Untitled episode"
		}
		n := Node{
			ID:     NewID("episode"),
			Type:   "episode",
			Tier:   "short",
			Status: "active",
			Title:  title,
			Body:   episodeBody(title, ep),
		}
		nodes = append(nodes, n)
		ids = append(ids, n.ID)

		// Link the episode from each hinted entity page (aliases resolved via
		// the index; unresolvable hints are dropped, never invented).
		link := "- [[" + n.ID + "|" + linkLabel(title) + "]]\n"
		for _, hint := range ep.EntityHints {
			en, rerr := Resolve(p.vault, p.db, hint)
			if rerr != nil {
				p.logf("memory: extract #%s: entity hint %q unresolved", w.ChannelName, hint)
				continue
			}
			if en.Type != "entity" || en.Status != "active" {
				continue
			}
			idx, seen := entityIdx[en.ID]
			if !seen {
				idx = len(nodes)
				entityIdx[en.ID] = idx
				nodes = append(nodes, en)
				ids = append(ids, en.ID)
			}
			nodes[idx].Body = appendToLinks(nodes[idx].Body, link)
		}
	}

	msg := CommitMsg{
		Op:      "extract",
		Summary: fmt.Sprintf("%d episodes from #%s", len(kept), w.ChannelName),
		Cause:   fmt.Sprintf("run:%d", runID),
		NodeIDs: ids,
	}
	if _, err := p.vault.WriteNodes(nodes, msg); err != nil {
		return 0, rejected, malformed, usage, err
	}
	now := time.Now().UTC().Format(time.RFC3339)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, n, now); err != nil {
			// The vault commit stands; the index is derived and the next
			// Reconcile repairs it, so this does not fail the window.
			p.logf("memory: index %s after extract: %v", n.ID, err)
		}
	}
	return len(kept), rejected, malformed, usage, nil
}

// episodeBody renders the v1 episode template for an extracted episode:
// H1 title, participants line, Story, Outcome, Provenance. (The template's
// time-range line is omitted in v1 — provenance ts values carry the range.)
func episodeBody(title string, ep extractedEpisode) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n", title)
	if len(ep.Participants) > 0 {
		fmt.Fprintf(&b, "Participants: %s\n\n", strings.Join(ep.Participants, ", "))
	}
	b.WriteString("## Story\n")
	if ep.Story != "" {
		b.WriteString(ep.Story + "\n")
	}
	b.WriteString("\n## Outcome\n")
	if ep.Outcome != nil && *ep.Outcome != "" {
		b.WriteString(*ep.Outcome + "\n")
	}
	b.WriteString("\n## Provenance\n")
	for _, r := range ep.Refs {
		fmt.Fprintf(&b, "- %s %s\n", r.ChannelID, r.TS)
	}
	return b.String()
}

// linkLabelReplacer strips characters that would break a [[id|label]]
// wiki-link out of AI-authored titles.
var linkLabelReplacer = strings.NewReplacer("[[", "", "]]", "", "|", "/", "\n", " ")

func linkLabel(title string) string {
	return linkLabelReplacer.Replace(title)
}

// appendToLinks adds a line as the first entry of the "## Links" section, or
// appends it to the end of the body when the section is absent (same shape as
// merge.go's appendMergedFrom, generalized to any line).
func appendToLinks(body, line string) string {
	loc := linksHeadingRe.FindStringIndex(body)
	if loc == nil {
		if body != "" && !strings.HasSuffix(body, "\n") {
			body += "\n"
		}
		return body + line
	}
	insertAt := loc[1]
	if insertAt < len(body) {
		insertAt++ // step over the heading's newline
	} else {
		body += "\n"
		insertAt = len(body)
	}
	return body[:insertAt] + line + body[insertAt:]
}

var (
	slackUserAliasRe    = regexp.MustCompile(`^[UW][A-Z0-9]{4,}$`)
	slackChannelAliasRe = regexp.MustCompile(`^[CDG][A-Z0-9]{4,}$`)
)

// mapEntry is one entity line in map.md.
type mapEntry struct {
	id, title, what string
}

// renderMap is consolidation step 5: the mechanical v1 map.md render — counts
// by type/tier, entities grouped people/channels/projects with one-line What
// excerpts, and the most recent open episodes. Committed via Vault.WriteFile
// (a byte-identical render adds no commit). The LLM-written map is Phase 3.
func (p *Pipeline) renderMap(runID int64) error {
	rows, err := p.db.ListMemoryNodes()
	if err != nil {
		return err
	}

	counts := make(map[string]int) // "type/tier" → count, tombstones excluded
	var people, channels, other []mapEntry
	var open []db.MemoryNodeRow
	for _, row := range rows {
		if row.Status == "tombstone" {
			continue
		}
		counts[row.Type+"/"+row.Tier]++
		switch row.Type {
		case "entity":
			n, err := p.vault.ReadNode(row.ID)
			if err != nil {
				p.logf("memory: map: read %s: %v", row.ID, err)
				continue
			}
			e := mapEntry{id: row.ID, title: row.Title, what: whatExcerpt(n.Body)}
			switch classifyEntity(n) {
			case "people":
				people = append(people, e)
			case "channels":
				channels = append(channels, e)
			default:
				other = append(other, e)
			}
		case "episode":
			if row.Status == "active" {
				open = append(open, row)
			}
		}
	}
	for _, group := range [][]mapEntry{people, channels, other} {
		sort.Slice(group, func(a, b int) bool {
			ta, tb := strings.ToLower(group[a].title), strings.ToLower(group[b].title)
			if ta != tb {
				return ta < tb
			}
			return group[a].id < group[b].id
		})
	}
	// Node IDs are ULIDs — sorting by ID descending is newest-first.
	sort.Slice(open, func(a, b int) bool { return open[a].ID > open[b].ID })
	if len(open) > mapOpenEpisodesCap {
		open = open[:mapOpenEpisodesCap]
	}

	var b strings.Builder
	b.WriteString("# Memory Map\n\n## Counts\n")
	for _, typ := range []string{"entity", "episode", "rollup", "belief"} {
		short, long := counts[typ+"/short"], counts[typ+"/long"]
		fmt.Fprintf(&b, "- %s: %d (short %d, long %d)\n", typ, short+long, short, long)
	}
	writeMapSection(&b, "People", people)
	writeMapSection(&b, "Channels", channels)
	writeMapSection(&b, "Projects & other", other)
	b.WriteString("\n## Recent open episodes\n")
	if len(open) == 0 {
		b.WriteString("(none)\n")
	}
	for _, row := range open {
		fmt.Fprintf(&b, "- [[%s|%s]]\n", row.ID, linkLabel(row.Title))
	}

	msg := CommitMsg{Op: "map", Summary: "render world map", Cause: fmt.Sprintf("run:%d", runID)}
	_, err = p.vault.WriteFile(mapFileName, []byte(b.String()), msg)
	return err
}

func writeMapSection(b *strings.Builder, heading string, entries []mapEntry) {
	fmt.Fprintf(b, "\n## %s\n", heading)
	if len(entries) == 0 {
		b.WriteString("(none)\n")
		return
	}
	for _, e := range entries {
		fmt.Fprintf(b, "- [[%s|%s]]", e.id, linkLabel(e.title))
		if e.what != "" {
			b.WriteString(" — " + e.what)
		}
		b.WriteString("\n")
	}
}

// classifyEntity buckets an entity page for the map by its natural-key
// aliases: Slack user IDs / emails / people-card refs → people, Slack
// channel-ish IDs or a "#name" title → channels, everything else (Jira
// project keys, hand-made pages) → other.
func classifyEntity(n Node) string {
	if n.Refs.PeopleCard != 0 {
		return "people"
	}
	for _, a := range n.Aliases {
		if slackUserAliasRe.MatchString(a) || strings.Contains(a, "@") {
			return "people"
		}
	}
	if strings.HasPrefix(n.Title, "#") {
		return "channels"
	}
	for _, a := range n.Aliases {
		if slackChannelAliasRe.MatchString(a) {
			return "channels"
		}
	}
	return "other"
}

// whatExcerpt returns the first non-empty line of the "## What" section,
// truncated for the one-line map render.
func whatExcerpt(body string) string {
	inWhat := false
	for _, line := range strings.Split(body, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "## ") {
			inWhat = trimmed == "## What"
			continue
		}
		if inWhat && trimmed != "" {
			if r := []rune(trimmed); len(r) > 120 {
				return string(r[:120]) + "…"
			}
			return trimmed
		}
	}
	return ""
}
