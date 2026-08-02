package memory

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
)

// IngestStats counts what one IngestSituations pass did: Created is new
// episode nodes for not-yet-ingested open situations, Updated is body
// rewrites of still-open already-ingested ones, Finalized is nodes closed
// because their situation transitioned to done/stale/converted. (Named
// IngestStats because the package's Stats is taken by Reconcile.)
type IngestStats struct {
	Created   int
	Updated   int
	Finalized int
}

// ingestSituation is the read-only projection of a situations row that the
// ingest mapping needs.
type ingestSituation struct {
	id                int
	title             string
	status            string
	summary           string
	chronology        string
	resolvedReason    string
	convertedTargetID int
	convertedTrackID  int
}

// IngestSituations mirrors situations into the memory vault as episode nodes
// (mechanical, no AI). A not-yet-ingested open situation becomes a tier:short
// active episode aliased "situation:<id>"; a situation that transitioned to
// done/stale/converted since ingest finalizes its node (status closed, tier
// long, Outcome from resolved_reason or the conversion link). "Already
// ingested" is detected purely via alias resolution and "needs finalize" by
// comparing node status vs situation status — nothing new is stored in the
// main DB, and inbox/situation tables are never written (MEM-05). Signal
// refs are re-validated before being written as provenance: ordinary Slack
// refs against messages (MEM-01), jira-detector signals against jira_issues
// via the jira: scheme (MEM-12) instead of being dropped against messages.
// All changes of a run land in one commit; a no-op run commits nothing.
//
// checker is the MEM-01 message-provenance lookup (the database in
// production; the pipeline passes its seam) — it is wrapped into this run's
// registry alongside the always-real-database jira resolver, built once per
// pass. A provenance lookup ERROR fails only that situation — it is logged
// and skipped this run, and ingest continues with the next situation, so one
// broken lookup cannot starve the whole mirror.
func IngestSituations(v *Vault, database *db.DB, checker messageChecker, logf func(string, ...any)) (IngestStats, error) {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	// The ingest registry: message refs validate through the passed-in checker
	// seam (so the MEM-01 lookup-freeze tests keep biting it), jira refs always
	// through the real database (jira_issues is a migration-guaranteed base
	// table, independent of the checker seam under test). Built once per pass,
	// not per signal (MEM-12).
	reg := newProvenanceRegistry(messageResolver{checker: checker}, jiraResolver{database})
	var stats IngestStats
	oldFloor, err := database.MemoryIngestFloor()
	if err != nil {
		return stats, err
	}
	sits, err := listIngestSituations(database, oldFloor)
	if err != nil {
		return stats, err
	}

	// The floor advances through the contiguous prefix of terminal situations
	// that settled this run (finalized or already-terminal). Walking ascending
	// by id, the first still-open OR transiently-skipped situation blocks any
	// further advance — a lower id must stay scannable (an open situation can
	// still transition; a skipped one must be retried). Situation ids are
	// monotonic (autoincrement), so this keeps the invariant "no open situation
	// has id <= floor": a future open situation always has id > floor.
	newFloor := oldFloor
	floorBlocked := false
	advanceFloor := func(s ingestSituation, pending bool) {
		if floorBlocked {
			return
		}
		if s.status == "open" || pending {
			floorBlocked = true
			return
		}
		if int64(s.id) > newFloor {
			newFloor = int64(s.id)
		}
	}

	var toWrite []Node
	var ids []string
	entityIdx := make(map[string]int) // entity node ID → index in toWrite, shared across situations
	for _, s := range sits {
		alias := fmt.Sprintf("situation:%d", s.id)
		nodeID, err := database.LookupMemoryAlias(alias)
		notIngested := errors.Is(err, sql.ErrNoRows)
		if err != nil && !notIngested {
			return stats, fmt.Errorf("memory: ingest lookup %q: %w", alias, err)
		}

		var (
			n       *Node
			hints   []string
			pending bool
		)
		if notIngested {
			n, hints, pending = ingestNewSituation(database, reg, logf, s, alias, &stats)
		} else {
			n, hints, pending = ingestExistingSituation(v, database, reg, logf, s, nodeID, &stats)
		}
		advanceFloor(s, pending)

		// The episode's id/title for linking purposes: a freshly-written
		// node's real generated id, or (when the episode body itself is a
		// no-op — unchanged/already-finalized) the already-known alias
		// lookup's nodeID + the situation's title, so back-links still
		// backfill without forcing a body rewrite. Empty only when the
		// situation never produced an episode at all (terminal-before-ever-
		// ingested), in which case there's nothing to link hints to.
		epID, epTitle := nodeID, s.title
		if n != nil {
			toWrite = append(toWrite, *n)
			ids = append(ids, n.ID)
			epID, epTitle = n.ID, n.Title
		}

		// Structural back-links: the situation's own channel(s) and signal
		// senders — exact Slack ids from situation_signals, no AI judgment
		// involved (mirrors buildEpisodeNodes' structural-hint path; MEM-05
		// holds, this only touches memory-vault entity nodes, never
		// inbox/situations rows). An entity touched by more than one
		// situation this run accumulates all of them via the shared
		// entityIdx (appendToLinks is idempotent against an exact-duplicate
		// line).
		if epID == "" || len(hints) == 0 {
			continue
		}
		link := "- [[" + epID + "|" + linkLabel(epTitle) + "]]\n"
		for _, hint := range hints {
			en, rerr := Resolve(v, database, hint)
			if rerr != nil || en.Type != "entity" || en.Status != "active" {
				continue // not yet seeded (or a bot) — silent, structural not model-authored
			}
			idx, seen := entityIdx[en.ID]
			if !seen {
				idx = len(toWrite)
				entityIdx[en.ID] = idx
				toWrite = append(toWrite, en)
				ids = append(ids, en.ID)
			}
			toWrite[idx].Body = appendToLinks(toWrite[idx].Body, link)
		}
	}

	if len(toWrite) > 0 {
		msg := CommitMsg{
			Op:      "ingest",
			Summary: ingestSummary(stats),
			Cause:   "ingest",
			NodeIDs: ids,
		}
		if _, err := v.WriteNodes(toWrite, msg); err != nil {
			return stats, err
		}
		now := time.Now().UTC().Format(time.RFC3339)
		mem := newOwnerEditedMemo(v)
		for _, n := range toWrite {
			if err := upsertIndexNode(database, mem.lookup, n, now); err != nil {
				return stats, err
			}
		}
	}

	// Advance the ingest floor after any commit succeeded (also on a settled
	// no-op run, so already-terminal situations stop being rescanned). A
	// workspace scalar, not a situations write — MEM-05 holds.
	if newFloor > oldFloor {
		if err := database.SetMemoryIngestFloor(newFloor); err != nil {
			return stats, err
		}
	}
	return stats, nil
}

// ingestNewSituation builds the episode node for a situation seen for the
// first time (nil when skipped), the structural entity hints its signals
// carry (channel + sender ids, for the caller to link — nil alongside a nil
// node), plus whether the skip is PENDING (a transient error to retry). Only
// open situations start a node; one already terminal before it was ever
// ingested predates memory and is skipped for good (settled, pending=false).
// A provenance lookup error is a transient skip (pending=true).
func ingestNewSituation(database *db.DB, reg *provenanceRegistry, logf func(string, ...any), s ingestSituation, alias string, stats *IngestStats) (*Node, []string, bool) {
	if s.status != "open" {
		return nil, nil, false // terminal & never ingested — settled, skipped for good
	}
	refs, hints, err := situationProvenance(database, reg, s.id, logf)
	if err != nil {
		logf("memory: ingest situation %d: %v — skipped this run", s.id, err)
		return nil, nil, true // transient — retry next run
	}
	stats.Created++
	return &Node{
		ID:      NewID("episode"),
		Type:    "episode",
		Tier:    "short",
		Status:  "active",
		Title:   s.title,
		Aliases: []string{alias},
		Body:    situationBody(s, refs),
	}, hints, false
}

// ingestExistingSituation refreshes or finalizes the already-ingested node for
// a situation (nil when untouched), the structural entity hints for the
// caller to link (returned even when the episode body itself is a no-op, so
// entity back-links can backfill without forcing a body rewrite), plus
// whether the skip is PENDING (a transient error to retry). A read error
// (corrupted/quarantined file) or a provenance lookup error is pending; an
// already-finalized node, an unchanged open one, or a normal update/finalize
// is settled (pending=false).
func ingestExistingSituation(v *Vault, database *db.DB, reg *provenanceRegistry, logf func(string, ...any), s ingestSituation, nodeID string, stats *IngestStats) (*Node, []string, bool) {
	n, err := v.ReadNode(nodeID)
	if err != nil {
		// A corrupted/quarantined episode file must not brick the whole
		// ingest pass (F4 spirit): skip this situation, keep going. The
		// alias row is preserved by Reconcile's quarantine, so the
		// situation is retried once the owner repairs the file.
		logf("memory: ingest situation %d: read %s: %v — skipped this run", s.id, nodeID, err)
		return nil, nil, true // transient — retry once the file is repaired
	}
	refs, hints, err := situationProvenance(database, reg, s.id, logf)
	if err != nil {
		logf("memory: ingest situation %d: %v — skipped this run", s.id, err)
		return nil, nil, true // transient — retry next run
	}
	if n.Status != "active" {
		return nil, hints, false // already finalized episode body — entity links still backfill
	}
	body := situationBody(s, refs)
	if s.status == "open" {
		if body == n.Body {
			return nil, hints, false // unchanged episode body — entity links still backfill
		}
		n.Title = s.title
		n.Body = body
		stats.Updated++
	} else {
		n.Status = "closed"
		n.Tier = "long"
		n.Title = s.title
		n.Body = body
		stats.Finalized++
	}
	return &n, hints, false
}

// listIngestSituations reads the situations relevant to ingest: every open one
// (create/update, always scanned) and done/stale/converted ones ABOVE the
// ingest floor (finalize). Dismissed and snoozed situations are excluded —
// dismissal means the owner declared the story noise, and a snooze is not a
// lifecycle transition. Terminal situations at or below the floor were already
// folded into the vault on a prior run and are skipped.
func listIngestSituations(database *db.DB, floor int64) ([]ingestSituation, error) {
	rows, err := database.Query(`
		SELECT id, title, status, summary, chronology, resolved_reason,
		       COALESCE(converted_target_id, 0), COALESCE(converted_track_id, 0)
		FROM situations
		WHERE status = 'open'
		   OR (status IN ('done', 'stale', 'converted') AND id > ?)
		ORDER BY id`, floor)
	if err != nil {
		return nil, fmt.Errorf("memory: ingest situations query: %w", err)
	}
	defer rows.Close()

	var out []ingestSituation
	for rows.Next() {
		var s ingestSituation
		if err := rows.Scan(&s.id, &s.title, &s.status, &s.summary, &s.chronology,
			&s.resolvedReason, &s.convertedTargetID, &s.convertedTrackID); err != nil {
			return nil, fmt.Errorf("memory: ingest situations scan: %w", err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// jiraProjectKey derives the project key from an issue key ("CEX-7413" →
// "CEX") — the entity-hint identity for jira-sourced signals (the project
// entity is what seedJiraProjects aliases; the issue itself is not an entity).
func jiraProjectKey(issueKey string) string {
	if i := strings.IndexByte(issueKey, '-'); i > 0 {
		return issueKey[:i]
	}
	return ""
}

// situationProvenance collects the situation's signal refs and re-validates
// them through reg (MEM-01/MEM-12): refs that positively do not resolve, or
// whose scheme is unregistered, are dropped (and logged), never repaired. A
// lookup error propagates — the caller skips this situation for the run
// rather than writing provenance it could not verify.
//
// It also returns the situation's structural entity hints — for an ordinary
// Slack-sourced signal, its distinct channel and sender ids; for a
// jira-detector signal (trigger_type "jira_*", whose channel_id carries the
// issue key rather than a Slack channel) the issue's PROJECT key instead,
// since the issue itself is never seeded as an entity. These come from
// situation_signals directly (not from the validated refs): a hint is a
// structural fact about the situation regardless of whether one particular
// ref later fails existence validation.
func situationProvenance(database *db.DB, reg *provenanceRegistry, situationID int, logf func(string, ...any)) (refs []episodeRef, hints []string, err error) {
	items, err := database.ListSituationSignals(situationID)
	if err != nil {
		return nil, nil, fmt.Errorf("memory: ingest signals for situation %d: %w", situationID, err)
	}
	refs = make([]episodeRef, 0, len(items))
	seen := make(map[string]bool, len(items)*2)
	addHint := func(id string) {
		if id == "" || seen[id] {
			return
		}
		seen[id] = true
		hints = append(hints, id)
	}
	for _, it := range items {
		if strings.HasPrefix(it.TriggerType, "jira_") {
			// A jira-detector signal: channel_id carries the issue key, which
			// never resolves in messages — mint a jira: ref instead (MEM-12)
			// and hint the PROJECT entity. TS is rendered as the parsed unix
			// seconds when MessageTS parses (indexable in memory_provenance,
			// ageable by eviction math, the calendar/builder precedent); on a
			// parse failure the raw MessageTS is tolerated as a fallback — the
			// ref still validates by key, it just won't index.
			ts := it.MessageTS
			if u, ok := db.ParseJiraTime(it.MessageTS); ok {
				ts = strconv.FormatInt(u, 10)
			}
			refs = append(refs, episodeRef{ChannelID: jiraRefPrefix + it.ChannelID, TS: ts})
			addHint(jiraProjectKey(it.ChannelID))
			continue
		}
		refs = append(refs, episodeRef{ChannelID: it.ChannelID, TS: it.MessageTS})
		addHint(it.ChannelID)
		addHint(it.SenderUserID)
	}
	kept, dropped, err := validateRefsVia(reg, []extractedEpisode{{Refs: refs}})
	if err != nil {
		return nil, nil, err
	}
	if dropped > 0 {
		logf("memory: ingest situation %d: refs_rejected=%d (MEM-01)", situationID, dropped)
	}
	if len(kept) == 0 {
		return nil, hints, nil
	}
	return kept[0].Refs, hints, nil
}

// situationBody renders the episode node body for a situation, per the v1
// episode template: H1 title, Story (summary + chronology as available),
// Outcome, Provenance. Fully deterministic so ingest can detect "unchanged"
// by comparing the rendered body against the node on disk.
func situationBody(s ingestSituation, refs []episodeRef) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n## Story\n", s.title)
	if s.summary != "" {
		b.WriteString(s.summary + "\n")
	}
	if s.chronology != "" {
		if s.summary != "" {
			b.WriteString("\n")
		}
		b.WriteString(s.chronology + "\n")
	}
	b.WriteString("\n## Outcome\n")
	if o := situationOutcome(s); o != "" {
		b.WriteString(o + "\n")
	}
	b.WriteString("\n## Provenance\n")
	for _, r := range refs {
		fmt.Fprintf(&b, "- %s %s\n", r.ChannelID, r.TS)
	}
	return b.String()
}

// situationOutcome renders the Outcome line: empty while open, the
// resolved_reason for done/stale, and the conversion link for converted
// situations (DASH-03: conversion is a link, not a delete — the memory node
// records where the story went).
func situationOutcome(s ingestSituation) string {
	if s.status == "open" {
		return ""
	}
	var parts []string
	if s.status == "converted" {
		var links []string
		if s.convertedTargetID != 0 {
			links = append(links, fmt.Sprintf("target #%d", s.convertedTargetID))
		}
		if s.convertedTrackID != 0 {
			links = append(links, fmt.Sprintf("track #%d", s.convertedTrackID))
		}
		parts = append(parts, "Converted to "+strings.Join(links, " and ")+".")
	}
	if s.resolvedReason != "" {
		parts = append(parts, s.resolvedReason)
	}
	if len(parts) == 0 {
		return "Closed as " + s.status + "."
	}
	return strings.Join(parts, " ")
}

// ingestSummary renders the commit summary, listing only the nonzero counts.
func ingestSummary(stats IngestStats) string {
	var parts []string
	if stats.Created > 0 {
		parts = append(parts, fmt.Sprintf("%d created", stats.Created))
	}
	if stats.Updated > 0 {
		parts = append(parts, fmt.Sprintf("%d updated", stats.Updated))
	}
	if stats.Finalized > 0 {
		parts = append(parts, fmt.Sprintf("%d finalized", stats.Finalized))
	}
	return strings.Join(parts, ", ")
}
