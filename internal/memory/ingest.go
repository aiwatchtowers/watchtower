package memory

import (
	"database/sql"
	"errors"
	"fmt"
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
// message refs are re-validated against messages before being written as
// provenance (MEM-01). All changes of a run land in one commit; a no-op run
// commits nothing.
func IngestSituations(v *Vault, database *db.DB) (IngestStats, error) {
	var stats IngestStats
	sits, err := listIngestSituations(database)
	if err != nil {
		return stats, err
	}

	var toWrite []Node
	var ids []string
	for _, s := range sits {
		alias := fmt.Sprintf("situation:%d", s.id)
		nodeID, err := database.LookupMemoryAlias(alias)
		notIngested := errors.Is(err, sql.ErrNoRows)
		if err != nil && !notIngested {
			return stats, fmt.Errorf("memory: ingest lookup %q: %w", alias, err)
		}

		if notIngested {
			// Only open situations start a node; one already closed before it
			// was ever ingested predates memory and is skipped for good.
			if s.status != "open" {
				continue
			}
			refs, err := situationProvenance(database, s.id)
			if err != nil {
				return stats, err
			}
			n := Node{
				ID:      NewID("episode"),
				Type:    "episode",
				Tier:    "short",
				Status:  "active",
				Title:   s.title,
				Aliases: []string{alias},
				Body:    situationBody(s, refs),
			}
			toWrite = append(toWrite, n)
			ids = append(ids, n.ID)
			stats.Created++
			continue
		}

		n, err := v.ReadNode(nodeID)
		if err != nil {
			return stats, err
		}
		if n.Status != "active" {
			continue // already finalized — terminal, untouched
		}
		refs, err := situationProvenance(database, s.id)
		if err != nil {
			return stats, err
		}
		body := situationBody(s, refs)
		if s.status == "open" {
			if body == n.Body {
				continue // unchanged — untouched
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
		toWrite = append(toWrite, n)
		ids = append(ids, n.ID)
	}

	if len(toWrite) == 0 {
		return stats, nil
	}
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
	for _, n := range toWrite {
		if err := upsertIndexNode(database, n, now); err != nil {
			return stats, err
		}
	}
	return stats, nil
}

// listIngestSituations reads the situations relevant to ingest: open ones
// (create/update) and done/stale/converted ones (finalize). Dismissed and
// snoozed situations are excluded — dismissal means the owner declared the
// story noise, and a snooze is not a lifecycle transition.
func listIngestSituations(database *db.DB) ([]ingestSituation, error) {
	rows, err := database.Query(`
		SELECT id, title, status, summary, chronology, resolved_reason,
		       COALESCE(converted_target_id, 0), COALESCE(converted_track_id, 0)
		FROM situations
		WHERE status IN ('open', 'done', 'stale', 'converted')
		ORDER BY id`)
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

// situationProvenance collects the situation's signal message refs and
// re-validates them through the same MEM-01 path as the extractor: refs that
// do not resolve against messages are dropped, never repaired.
func situationProvenance(database *db.DB, situationID int) ([]episodeRef, error) {
	items, err := database.ListSituationSignals(situationID)
	if err != nil {
		return nil, fmt.Errorf("memory: ingest signals for situation %d: %w", situationID, err)
	}
	refs := make([]episodeRef, 0, len(items))
	for _, it := range items {
		refs = append(refs, episodeRef{ChannelID: it.ChannelID, TS: it.MessageTS})
	}
	kept, _ := validateRefs(database, []extractedEpisode{{Refs: refs}})
	if len(kept) == 0 {
		return nil, nil
	}
	return kept[0].Refs, nil
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
