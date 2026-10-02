package targets

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"watchtower/internal/db"
)

// LinkResult holds the AI-proposed parent and secondary links for an existing target.
type LinkResult struct {
	ParentID       sql.NullInt64
	SecondaryLinks []ProposedLink
}

// aiLinkResponse is the raw JSON for the link prompt response.
type aiLinkResponse struct {
	ParentID       *int64            `json:"parent_id"`
	SecondaryLinks []aiSecondaryLink `json:"secondary_links"`
}

// buildLinkPrompt assembles the smaller prompt for single-target linking.
// tmpl is the resolved template (store override or the registered targets.link default) — the
// function itself stays pure, with no store access.
func buildLinkPrompt(tmpl string, target db.Target, snapshot []db.Target) string {
	intent := ""
	if target.Intent != "" {
		intent = "Intent: " + target.Intent
	}

	snapshotBlock := ""
	if len(snapshot) > 0 {
		var sb strings.Builder
		sb.WriteString("=== ACTIVE TARGETS ===\n")
		for _, t := range snapshot {
			if t.ID == target.ID {
				continue // skip self
			}
			sb.WriteString(fmt.Sprintf("[id=%d level=%s period=%s..%s priority=%s status=%s] %s\n",
				t.ID, t.Level, t.PeriodStart, t.PeriodEnd, t.Priority, t.Status, t.Text))
		}
		sb.WriteString("=== /ACTIVE TARGETS ===")
		snapshotBlock = sb.String()
	}

	return fmt.Sprintf(tmpl,
		target.ID, target.Level, target.PeriodStart, target.PeriodEnd,
		target.Priority, target.Status, target.Text,
		intent,
		snapshotBlock,
	)
}

// parseLinkResponse parses the AI link response, validates ids against the
// snapshot. forbiddenParents holds the ids that cannot be the target's parent
// (the target itself and its descendants — either would make it its own
// ancestor); a proposed parent among them is dropped like an unknown id.
// selfID is the linked target's own id: a secondary link to it is dropped.
func parseLinkResponse(raw string, snapshot []db.Target, selfID int64, forbiddenParents map[int64]bool) (*LinkResult, error) {
	raw = strings.TrimSpace(raw)
	// Strip markdown fences.
	if strings.HasPrefix(raw, "```") {
		lines := strings.SplitN(raw, "\n", 2)
		if len(lines) == 2 {
			raw = lines[1]
		}
		if idx := strings.LastIndex(raw, "```"); idx >= 0 {
			raw = raw[:idx]
		}
		raw = strings.TrimSpace(raw)
	}

	var resp aiLinkResponse
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		return nil, fmt.Errorf("parsing AI link response: %w", err)
	}

	// Build snapshot id set.
	snapshotIDs := make(map[int64]bool, len(snapshot))
	for _, t := range snapshot {
		snapshotIDs[int64(t.ID)] = true
	}

	result := &LinkResult{}

	result.ParentID = validParentID(resp.ParentID, snapshotIDs, forbiddenParents)

	// Cap secondary links at 3.
	links := resp.SecondaryLinks
	if len(links) > 3 {
		links = links[:3]
	}

	validRelations := map[string]bool{
		"contributes_to": true,
		"blocks":         true,
		"related":        true,
		"duplicates":     true,
	}

	for _, sl := range links {
		if !validRelations[sl.Relation] {
			continue
		}
		// Validate external_ref allowlist.
		if sl.ExternalRef != "" && !IsValidExternalRef(sl.ExternalRef) {
			continue // drop invalid external refs silently in AI path
		}
		pl := ProposedLink{
			ExternalRef: sl.ExternalRef,
			Relation:    sl.Relation,
		}
		if sl.Confidence > 0 {
			pl.Confidence = sql.NullFloat64{Float64: sl.Confidence, Valid: true}
		}
		if sl.TargetID != nil {
			if !snapshotIDs[*sl.TargetID] || *sl.TargetID == selfID {
				continue // drop unknown id or a link to the target itself
			}
			pl.TargetID = sql.NullInt64{Int64: *sl.TargetID, Valid: true}
		}
		if !pl.TargetID.Valid && pl.ExternalRef == "" {
			continue
		}
		result.SecondaryLinks = append(result.SecondaryLinks, pl)
	}

	return result, nil
}

// validParentID keeps a proposed parent only when it is in the snapshot and
// not forbidden (the target itself or one of its descendants).
func validParentID(id *int64, snapshotIDs, forbidden map[int64]bool) sql.NullInt64 {
	if id == nil || !snapshotIDs[*id] || forbidden[*id] {
		return sql.NullInt64{}
	}
	return sql.NullInt64{Int64: *id, Valid: true}
}

// maxParentWalkDepth bounds forbiddenParentIDs' ancestor walk, matching the
// RecomputeParentProgress cap, so a pre-existing cycle cannot loop forever.
const maxParentWalkDepth = 20

// errParentWalkTooDeep reports an ancestor chain longer than
// maxParentWalkDepth: the walk cannot prove the chain never reaches the target.
var errParentWalkTooDeep = errors.New("ancestor chain deeper than the walk cap")

// parentLookup resolves a target's parent: ok=false means it has none (or
// does not exist); a non-nil error means the parent could not be read.
type parentLookup func(id int64) (parent int64, ok bool, err error)

// forbiddenParentIDs returns targetID plus every snapshot target that has
// targetID among its ancestors: making any of them targetID's parent would
// create a cycle. parentOf resolves a target outside the snapshot (an
// intermediate ancestor the snapshot limit cut off). It fails closed: when an
// ancestor cannot be read or a chain exceeds maxParentWalkDepth, it returns an
// error and the caller must not propose any parent.
func forbiddenParentIDs(targetID int64, snapshot []db.Target, parentOf parentLookup) (map[int64]bool, error) {
	known := make(map[int64]sql.NullInt64, len(snapshot))
	for _, t := range snapshot {
		known[int64(t.ID)] = t.ParentID
	}
	parent := func(id int64) (int64, bool, error) {
		if p, ok := known[id]; ok {
			return p.Int64, p.Valid, nil
		}
		return parentOf(id)
	}

	forbidden := map[int64]bool{targetID: true}
	for _, t := range snapshot {
		reaches, err := chainReaches(int64(t.ID), targetID, parent)
		if err != nil {
			return nil, fmt.Errorf("checking ancestors of target %d: %w", t.ID, err)
		}
		if reaches {
			forbidden[int64(t.ID)] = true
		}
	}
	return forbidden, nil
}

// chainReaches walks start's ancestor chain and reports whether it passes
// through targetID. A root or a pre-existing cycle ends the walk cleanly; a
// lookup error or a chain longer than maxParentWalkDepth is an error.
func chainReaches(start, targetID int64, parent parentLookup) (bool, error) {
	visited := map[int64]bool{}
	id := start
	for depth := 0; depth < maxParentWalkDepth; depth++ {
		if visited[id] {
			return false, nil
		}
		visited[id] = true
		pid, ok, err := parent(id)
		if err != nil || !ok {
			return false, err
		}
		if pid == targetID {
			return true, nil
		}
		id = pid
	}
	return false, errParentWalkTooDeep
}
