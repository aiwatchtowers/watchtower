package memory

// This file is the Phase-5 5C mechanical operational-mirror builder (behind
// memory.sources.operational): a no-AI Run step (3c, after the calendar builder
// 3b and before Slack extraction 4) that mirrors the owner's own work items —
// targets and tracks — into the vault as long-lived ENTITY nodes (a target/track
// is a state machine, not a story arc, so it is an entity, not an episode). Each
// mirror carries:
//
//   - ## What      — the item's identity (target text/intent/level/period; track
//     text/category/ownership), regenerated each refresh;
//   - ## Current   — its operational state (status/priority/ball-on/due/next step
//     or track sub-item progress), replaced WHOLESALE each refresh (it mirrors
//     relational state, it is not an append journal);
//   - ## Facts     — preserved verbatim; with mirrors excluded from the rewrite
//     tier its only writer is the owner's own vault edits (MEM-03);
//   - ## Links     — conversion cross-links to the originating situation:<id>
//     episode (DASH-03 closed inside the vault), accreted via appendToLinks;
//   - ## Open loops — the open sub-items + a ball-on/due line while the row is
//     non-terminal, CLEARED (empty section, heading kept) when it is terminal.
//
// Idempotency is alias-keyed (target:<id> / track:<id>, the calevent:/situation:
// precedent): a re-scan UPDATEs the mirror in place, and a byte-equality check
// makes an unchanged re-scan a no-op (no empty git commit). There is NO watermark
// and NO time window — targets/tracks are small mutable tables, so the step
// re-scans EVERY row each run and decides per row against the existing-mirror
// alias set (db.MirrorAliasNodeIDs, loaded once): the implemented skip predicate
// is that a terminal row (target done/dismissed; track dismissed) with NO existing
// mirror is never mirrored — it is skipped immediately, before any body work;
// every other row (active, or terminal WITH an existing mirror) is built/refreshed
// against its preloaded node id, the byte-equality check keeping an unchanged
// refresh free. A terminal row's mirror therefore always tracks the terminal
// transition (its ## Open loops clear) no matter how long ago the row settled —
// the old updated_at window stranded stale-dismissed mirrors forever. Known
// limitation: a target/track created AND driven terminal between two pipeline runs
// never gets a mirror (no existing alias at scan time); its story still reaches
// memory via the situation episodes — a conservative default, no counter. It is a pure READER
// of targets/tracks/situations (MEM-14): every write lands in the vault or the
// memory index.

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

func targetMirrorAlias(id int) string { return fmt.Sprintf("target:%d", id) }
func trackMirrorAlias(id int) string  { return fmt.Sprintf("track:%d", id) }

// runOperationalMirrors is Run step 3c (behind memory.sources.operational): the
// mechanical, no-AI mirror of targets/tracks into vault entity nodes. It scans
// the candidate rows, rebuilds each mirror body deterministically, commits the
// changed ones as ONE vault commit, and records one pipeline_steps row named
// "mirror" at stepOffset+1. A read/resolve DB error fails the step (logged,
// RunStats.MirrorsFailed) but is never fatal to the run (the calendar-step
// isolation contract). Returns the number of step rows recorded (always 1).
func (p *Pipeline) runOperationalMirrors(runID int64, stepOffset int, stats *RunStats) (int, error) {
	start := time.Now()
	step := stepOffset + 1

	targets, err := p.db.ListTargetsForMirror()
	if err != nil {
		stats.MirrorsFailed++
		p.recordSemanticStep(runID, &step, "mirror", "error", nil, start)
		return 1, err
	}
	tracks, err := p.db.ListTracksForMirror()
	if err != nil {
		stats.MirrorsFailed++
		p.recordSemanticStep(runID, &step, "mirror", "error", nil, start)
		return 1, err
	}

	built, berr := p.buildOperationalMirrors(runID, targets, tracks)
	if berr != nil {
		// A resolve/read/commit failure freezes the whole step: nothing is
		// committed and every candidate re-scans next run (source isolation).
		stats.MirrorsFailed++
		p.logf("memory: operational mirrors: %v", berr)
	} else {
		stats.Mirrored += built
	}
	p.recordSemanticStep(runID, &step, "mirror", stepStatus(berr), nil, start)
	return 1, nil
}

// buildOperationalMirrors rebuilds every candidate target/track mirror and
// commits the changed ones as ONE vault commit + index mirror. It loads the
// existing-mirror alias set ONCE and skips a terminal row that has NO existing
// mirror (before conversionLinks, before any body work — never mirrored); every
// other row is built/refreshed against its preloaded node id. Mirrors never share
// nodes (each row has its own alias), so a plain append suffices — no dedup. It
// returns the number of mirrors created-or-refreshed (built) and an error that
// freezes the whole step (an alias-set/read/resolve/commit failure — the alias set
// is the idempotency key, loaded once up front, so a load failure returns before
// any row is built rather than risk minting the very duplicate it prevents). An
// all-unchanged run commits nothing.
func (p *Pipeline) buildOperationalMirrors(runID int64, targets []db.MirrorTarget, tracks []db.MirrorTrack) (built int, err error) {
	mirrors, err := p.db.MirrorAliasNodeIDs()
	if err != nil {
		return 0, fmt.Errorf("memory: operational mirror: alias set: %w", err)
	}

	var nodes []Node
	for _, t := range targets {
		existingID, ok := mirrors[targetMirrorAlias(t.ID)]
		if t.Terminal && !ok {
			continue // terminal with no existing mirror — never mirrored
		}
		n, changed, merr := p.targetMirrorNode(t, existingID, ok)
		if merr != nil {
			return 0, merr
		}
		if changed {
			nodes = append(nodes, *n)
			built++
		}
	}
	for _, t := range tracks {
		existingID, ok := mirrors[trackMirrorAlias(t.ID)]
		if t.Terminal && !ok {
			continue // terminal with no existing mirror — never mirrored
		}
		n, changed, merr := p.trackMirrorNode(t, existingID, ok)
		if merr != nil {
			return 0, merr
		}
		if changed {
			nodes = append(nodes, *n)
			built++
		}
	}

	if cerr := p.commitMirrorNodes(runID, nodes); cerr != nil {
		return 0, cerr
	}
	return built, nil
}

// commitMirrorNodes writes the changed mirrors as one memory(mirror) commit +
// index mirror. An all-unchanged run commits nothing (no empty git commit). A
// commit failure freezes the step; an index-mirror error is non-fatal (reconcile
// self-heals).
func (p *Pipeline) commitMirrorNodes(runID int64, nodes []Node) error {
	if len(nodes) == 0 {
		return nil
	}
	ids := make([]string, len(nodes))
	for i, n := range nodes {
		ids[i] = n.ID
	}
	msg := CommitMsg{
		Op:      "mirror",
		Summary: fmt.Sprintf("%d target/track mirror(s)", len(ids)),
		Cause:   fmt.Sprintf("run:%d", runID),
		NodeIDs: ids,
	}
	if _, err := p.vault.WriteNodes(nodes, msg); err != nil {
		return err
	}
	now := time.Now().UTC().Format(time.RFC3339)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, n, now); err != nil {
			p.logf("memory: index %s after operational mirror: %v", n.ID, err)
		}
	}
	return nil
}

// targetMirrorNode returns the entity node for one target's mirror plus whether
// it is new-or-changed. The caller has already skipped a terminal target with no
// mirror, so this always builds/refreshes; it passes the preloaded existing
// node id (exists=false → create) so no per-row alias lookup is needed. It stamps
// Refs.Targets with the id.
func (p *Pipeline) targetMirrorNode(t db.MirrorTarget, existingID string, exists bool) (*Node, bool, error) {
	links, err := p.conversionLinks(t.ID, 0)
	if err != nil {
		return nil, false, err
	}
	loops := ""
	if !t.Terminal {
		loops = targetOpenLoops(t)
	}
	return p.mirrorNode(mirrorSpec{
		alias:      targetMirrorAlias(t.ID),
		existingID: existingID,
		exists:     exists,
		title:      targetMirrorTitle(t),
		what:       targetWhat(t),
		current:    targetCurrent(t),
		loops:      loops,
		crossLinks: links,
		targetRefs: []int64{int64(t.ID)},
	})
}

// trackMirrorNode returns the entity node for one track's mirror plus whether it
// is new-or-changed (the caller has already skipped a terminal track with no
// mirror and passes the preloaded existing node id, so no per-row alias lookup is
// needed). Tracks carry no Refs.Targets.
func (p *Pipeline) trackMirrorNode(t db.MirrorTrack, existingID string, exists bool) (*Node, bool, error) {
	links, err := p.conversionLinks(0, t.ID)
	if err != nil {
		return nil, false, err
	}
	loops := ""
	if !t.Terminal {
		loops = trackOpenLoops(t)
	}
	return p.mirrorNode(mirrorSpec{
		alias:      trackMirrorAlias(t.ID),
		existingID: existingID,
		exists:     exists,
		title:      trackMirrorTitle(t),
		what:       trackWhat(t),
		current:    trackCurrent(t),
		loops:      loops,
		crossLinks: links,
	})
}

// crossLink is one conversion cross-link: the target episode's node id (the
// dedupe key) and its rendered "- [[id|title]]" ## Links line.
type crossLink struct {
	epID string
	line string
}

// mirrorSpec bundles the deterministic mirror render inputs. existingID/exists is
// the preloaded alias→node_id lookup from buildOperationalMirrors' one-shot
// MirrorAliasNodeIDs map (exists=false → create a fresh entity); the mirror step
// is the only writer of these aliases and commits after the loop, so the map stays
// authoritative for the whole scan and no per-row lookup is needed.
type mirrorSpec struct {
	alias      string
	existingID string
	exists     bool
	title      string
	what       string
	current    string
	loops      string
	crossLinks []crossLink
	targetRefs []int64
}

// mirrorNode is the alias-keyed idempotency + rebuild core: with no existing mirror
// (spec.exists=false) it creates a fresh entity; with one it reads the node,
// preserves its ## Facts / ## Links, regenerates ## What / ## Current /
// ## Open loops, accretes the conversion cross-links (deduped by episode id,
// appendCrossLink), and reports changed=false on a byte-identical rebuild (no
// commit). The caller has already skipped a terminal row with no mirror, so the
// create branch is only ever reached by a live (non-terminal) row. A read error
// fails the step.
func (p *Pipeline) mirrorNode(spec mirrorSpec) (*Node, bool, error) {
	if spec.exists {
		existing, rerr := p.vault.ReadNode(spec.existingID)
		if rerr != nil {
			return nil, false, fmt.Errorf("memory: operational mirror: read %s for %q: %w", spec.existingID, spec.alias, rerr)
		}
		facts := mirrorSectionContent(existing.Body, "## Facts")
		links := mirrorSectionContent(existing.Body, "## Links")
		body := mirrorBody(spec.title, spec.what, spec.current, facts, links, spec.loops)
		for _, cl := range spec.crossLinks {
			body = appendCrossLink(body, cl.epID, cl.line)
		}
		if existing.Title == spec.title && existing.Body == body {
			return &existing, false, nil // unchanged — no commit
		}
		existing.Title = spec.title
		existing.Body = body
		existing.Aliases = ensureAlias(existing.Aliases, spec.alias)
		if len(spec.targetRefs) > 0 {
			existing.Refs.Targets = spec.targetRefs
		}
		return &existing, true, nil
	}
	body := mirrorBody(spec.title, spec.what, spec.current, "", "", spec.loops)
	for _, cl := range spec.crossLinks {
		body = appendCrossLink(body, cl.epID, cl.line)
	}
	n := Node{
		ID:      NewID("entity"),
		Type:    "entity",
		Tier:    "long",
		Status:  "active",
		Title:   spec.title,
		Aliases: []string{spec.alias},
		Body:    body,
	}
	if len(spec.targetRefs) > 0 {
		n.Refs.Targets = spec.targetRefs
	}
	return &n, true, nil
}

// conversionLinks resolves the DASH-03 conversion cross-links for one mirror:
// each situation converted into this target/track resolves via its situation:<id>
// alias to the episode node, and yields a crossLink{epID, "- [[ep_…|title]]"}. A
// situation not yet ingested (alias miss) is a silent skip, backfilled on a later
// re-scan; any other lookup error freezes the step.
func (p *Pipeline) conversionLinks(targetID, trackID int) ([]crossLink, error) {
	sitIDs, err := p.db.ConvertedSituationIDs(targetID, trackID)
	if err != nil {
		return nil, err
	}
	var links []crossLink
	for _, sid := range sitIDs {
		epID, lerr := p.db.LookupMemoryAlias(fmt.Sprintf("situation:%d", sid))
		if errors.Is(lerr, sql.ErrNoRows) {
			continue // not yet ingested — silent skip, backfilled later
		}
		if lerr != nil {
			return nil, fmt.Errorf("memory: operational mirror: situation alias %d: %w", sid, lerr)
		}
		row, rerr := p.db.GetMemoryNode(epID)
		if rerr != nil {
			return nil, fmt.Errorf("memory: operational mirror: episode node %s: %w", epID, rerr)
		}
		links = append(links, crossLink{epID: epID, line: "- [[" + epID + "|" + linkLabel(row.Title) + "]]\n"})
	}
	return links, nil
}

// appendCrossLink appends a conversion cross-link to ## Links UNLESS a link to the
// same episode id is already present ANYWHERE in the body (a "[[<epID>" substring
// match over the whole node, not scoped to ## Links). It dedupes by node id, not by
// the fully rendered line, so a later change to the linked episode's title never
// accretes a second link line for the same episode. The body-wide scope is
// acceptable because a mirror only ever renders an "[[<epID>" token as a conversion
// cross-link in ## Links — no other section emits that token — so a body-wide hit
// is always the ## Links line we would re-append.
func appendCrossLink(body, epID, line string) string {
	if strings.Contains(body, "[["+epID) {
		return body
	}
	return appendToLinks(body, line)
}

// mirrorBody renders the deterministic entity mirror body in the entitySkeletonBody
// section order (What / Current / Facts / Links / Open loops). facts and links are
// preserved verbatim from the existing node (or "" on create); what/current/loops
// are regenerated from the row. Deterministic so the byte-equality check detects
// an unchanged re-scan; round-trips through appendToLinks (Links) so a preserved
// cross-link re-adds idempotently.
func mirrorBody(title, what, current, facts, links, loops string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n", title)
	writeMirrorSection(&b, "## What", what, false)
	writeMirrorSection(&b, "## Current", current, false)
	writeMirrorSection(&b, "## Facts", facts, false)
	writeMirrorSection(&b, "## Links", links, false)
	writeMirrorSection(&b, "## Open loops", loops, true)
	return b.String()
}

// writeMirrorSection writes one "## Heading" section: the heading, the content
// (when non-empty, newline-terminated), then a trailing blank-line separator
// unless it is the last section. Matches the entitySkeletonBody blank-line
// discipline so the create/refresh forms are self-consistent.
func writeMirrorSection(b *strings.Builder, heading, content string, last bool) {
	b.WriteString(heading + "\n")
	if content != "" {
		b.WriteString(content + "\n")
	}
	if !last {
		b.WriteString("\n")
	}
}

// mirrorSectionContent returns the content lines under heading (between it and the
// next "## " heading), with surrounding blank lines trimmed and no trailing
// newline — the inverse of writeMirrorSection, so preserve→rebuild round-trips.
func mirrorSectionContent(body, heading string) string {
	var out []string
	in := false
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "## ") {
			if strings.TrimRight(line, " \t") == heading {
				in, out = true, nil
				continue
			}
			if in {
				break
			}
			continue
		}
		if in {
			out = append(out, line)
		}
	}
	for len(out) > 0 && strings.TrimSpace(out[0]) == "" {
		out = out[1:]
	}
	for len(out) > 0 && strings.TrimSpace(out[len(out)-1]) == "" {
		out = out[:len(out)-1]
	}
	return strings.Join(out, "\n")
}

// --- target renderers ---

func targetMirrorTitle(t db.MirrorTarget) string {
	return firstNonEmpty(oneLine(t.Text), fmt.Sprintf("target #%d", t.ID))
}

// targetWhat renders the target's identity: its text, intent, and level/period.
func targetWhat(t db.MirrorTarget) string {
	var lines []string
	if s := oneLine(t.Text); s != "" {
		lines = append(lines, s)
	}
	if s := oneLine(t.Intent); s != "" {
		lines = append(lines, "Intent: "+s)
	}
	level := strings.TrimSpace(t.Level)
	if level == "custom" && strings.TrimSpace(t.CustomLabel) != "" {
		level = oneLine(t.CustomLabel)
	}
	if level != "" {
		if period := mirrorPeriod(t.PeriodStart, t.PeriodEnd); period != "" {
			lines = append(lines, "Level: "+level+" ("+period+")")
		} else {
			lines = append(lines, "Level: "+level)
		}
	}
	return strings.Join(lines, "\n")
}

// targetCurrent renders the target's operational state (replaced wholesale each
// refresh).
func targetCurrent(t db.MirrorTarget) string {
	var lines []string
	if s := strings.TrimSpace(t.Status); s != "" {
		lines = append(lines, "Status: "+s)
	}
	if s := strings.TrimSpace(t.Priority); s != "" {
		lines = append(lines, "Priority: "+s)
	}
	if s := oneLine(t.BallOn); s != "" {
		lines = append(lines, "Ball on: "+s)
	}
	if s := strings.TrimSpace(t.DueDate); s != "" {
		lines = append(lines, "Due: "+s)
	}
	if s := nextStepTitle(t.NextStep); s != "" {
		lines = append(lines, "Next step: "+s)
	}
	return strings.Join(lines, "\n")
}

// targetOpenLoops renders the target's open loops: each not-done sub-item, then a
// ball-on/due line. Empty (and cleared by the caller) once the target is terminal.
// When the target is SNOOZED, every loop bullet is tagged " (target snoozed)":
// snoozed targets are deliberately absent from the day plan's ACTIVE TASKS, so
// without this status context the day-plan model has nothing to dedupe against and
// could resurface deliberately-deferred work as if it were live.
func targetOpenLoops(t db.MirrorTarget) string {
	suffix := ""
	if t.Status == "snoozed" { // DB CHECK constrains status to exact lowercase
		suffix = " (target snoozed)"
	}
	var lines []string
	for _, si := range parseTargetSubItems(t.SubItems) {
		if si.Done {
			continue
		}
		if txt := oneLine(si.Text); txt != "" {
			lines = append(lines, "- "+txt+suffix)
		}
	}
	if bl := ballDueLine(t.BallOn, t.DueDate); bl != "" {
		lines = append(lines, bl+suffix)
	}
	return strings.Join(lines, "\n")
}

// --- track renderers ---

func trackMirrorTitle(t db.MirrorTrack) string {
	return firstNonEmpty(oneLine(t.Text), fmt.Sprintf("track #%d", t.ID))
}

// trackWhat renders the track's identity: its text, category, and ownership.
func trackWhat(t db.MirrorTrack) string {
	var lines []string
	if s := oneLine(t.Text); s != "" {
		lines = append(lines, s)
	}
	if s := strings.TrimSpace(t.Category); s != "" {
		lines = append(lines, "Category: "+s)
	}
	if s := strings.TrimSpace(t.Ownership); s != "" {
		lines = append(lines, "Ownership: "+s)
	}
	return strings.Join(lines, "\n")
}

// trackCurrent renders the track's operational state, including sub-item progress.
func trackCurrent(t db.MirrorTrack) string {
	var lines []string
	if t.Terminal {
		lines = append(lines, "Status: dismissed")
	} else {
		lines = append(lines, "Status: active")
	}
	if s := strings.TrimSpace(t.Priority); s != "" {
		lines = append(lines, "Priority: "+s)
	}
	if s := oneLine(t.BallOn); s != "" {
		lines = append(lines, "Ball on: "+s)
	}
	if d := mirrorUnixDate(t.DueDate); d != "" {
		lines = append(lines, "Due: "+d)
	}
	if done, total := trackSubItemProgress(t.SubItems); total > 0 {
		lines = append(lines, fmt.Sprintf("Sub-items: %d/%d done", done, total))
	}
	return strings.Join(lines, "\n")
}

// trackOpenLoops renders the track's open loops: each not-done sub-item, then a
// ball-on/due line. Empty (and cleared) once the track is dismissed.
func trackOpenLoops(t db.MirrorTrack) string {
	var lines []string
	for _, si := range parseTrackSubItems(t.SubItems) {
		if strings.EqualFold(strings.TrimSpace(si.Status), "done") {
			continue
		}
		if txt := oneLine(si.Text); txt != "" {
			lines = append(lines, "- "+txt)
		}
	}
	if bl := ballDueLine(t.BallOn, mirrorUnixDate(t.DueDate)); bl != "" {
		lines = append(lines, bl)
	}
	return strings.Join(lines, "\n")
}

// --- shared render helpers ---

// ballDueLine renders the "- ball on X, due Y" open-loops line, dropping the
// parts that are empty (and returning "" when both are).
func ballDueLine(ballOn, due string) string {
	var parts []string
	if s := oneLine(ballOn); s != "" {
		parts = append(parts, "ball on "+s)
	}
	if s := strings.TrimSpace(due); s != "" {
		parts = append(parts, "due "+s)
	}
	if len(parts) == 0 {
		return ""
	}
	return "- " + strings.Join(parts, ", ")
}

// mirrorPeriod renders a target's period as "start–end" (or "start" when they
// match, "" when both are empty).
func mirrorPeriod(start, end string) string {
	start, end = strings.TrimSpace(start), strings.TrimSpace(end)
	switch {
	case start == "" && end == "":
		return ""
	case end == "" || start == end:
		return start
	case start == "":
		return end
	default:
		return start + "–" + end
	}
}

// mirrorUnixDate renders a unix-seconds due date as a YYYY-MM-DD UTC day, or ""
// for the 0 (no-deadline) sentinel.
func mirrorUnixDate(unix float64) string {
	if unix == 0 {
		return ""
	}
	return time.Unix(int64(unix), 0).UTC().Format("2006-01-02")
}

// targetSubItem / trackSubItem are the read projections of a sub-item across the
// two JSON shapes: a target sub-item is {text, done}, a track sub-item is
// {text, status}.
type targetSubItem struct {
	Text string `json:"text"`
	Done bool   `json:"done"`
}

type trackSubItem struct {
	Text   string `json:"text"`
	Status string `json:"status"`
}

// parseTargetSubItems decodes a target's sub_items JSON ([{text, done, …}]),
// tolerating a malformed/empty value as no sub-items (the defensive-skip
// precedent).
func parseTargetSubItems(raw string) []targetSubItem {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	var out []targetSubItem
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		return nil
	}
	return out
}

// parseTrackSubItems decodes a track's sub_items JSON ([{text, status}]),
// tolerating a malformed/empty value as no sub-items.
func parseTrackSubItems(raw string) []trackSubItem {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	var out []trackSubItem
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		return nil
	}
	return out
}

// trackSubItemProgress returns (done, total) over a track's sub-items.
func trackSubItemProgress(raw string) (done, total int) {
	for _, si := range parseTrackSubItems(raw) {
		if strings.TrimSpace(si.Text) == "" {
			continue
		}
		total++
		if strings.EqualFold(strings.TrimSpace(si.Status), "done") {
			done++
		}
	}
	return done, total
}

// nextStepTitle extracts a target's next_step JSON title (the imperative
// one-liner), "" when absent or malformed.
func nextStepTitle(raw string) string {
	if strings.TrimSpace(raw) == "" {
		return ""
	}
	var ns struct {
		Title string `json:"title"`
	}
	if err := json.Unmarshal([]byte(raw), &ns); err != nil {
		return ""
	}
	return oneLine(ns.Title)
}
