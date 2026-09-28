package targets

import (
	"database/sql"
	"encoding/json"
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
// tmpl is the resolved template (store override or LinkPromptTemplate) — the
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

// forbiddenParentIDs returns targetID plus every snapshot target that has
// targetID among its ancestors: making any of them targetID's parent would
// create a cycle. parentOf resolves a target outside the snapshot (an
// intermediate ancestor the snapshot limit cut off); ok=false stops the walk.
func forbiddenParentIDs(targetID int64, snapshot []db.Target, parentOf func(id int64) (parent int64, ok bool)) map[int64]bool {
	known := make(map[int64]sql.NullInt64, len(snapshot))
	for _, t := range snapshot {
		known[int64(t.ID)] = t.ParentID
	}
	parent := func(id int64) (int64, bool) {
		if p, ok := known[id]; ok {
			return p.Int64, p.Valid
		}
		return parentOf(id)
	}

	forbidden := map[int64]bool{targetID: true}
	for _, t := range snapshot {
		visited := map[int64]bool{}
		id := int64(t.ID)
		for depth := 0; depth < maxParentWalkDepth && !visited[id]; depth++ {
			visited[id] = true
			pid, ok := parent(id)
			if !ok {
				break
			}
			if pid == targetID {
				forbidden[int64(t.ID)] = true
				break
			}
			id = pid
		}
	}
	return forbidden
}
