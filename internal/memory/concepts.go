package memory

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// PromoteConcepts turns recurring extractor entity hints into concept entity
// pages — the vocabulary-broadening mechanism (spec goal 6). It is purely
// MECHANICAL: a hint that recurred across at least minEpisodes distinct
// episodes becomes a new entity node (kind "concept" is implicit — it is a
// plain entity carrying only the normalized-hint alias, no people-card/channel
// alias), with the contributing episodes back-linked into its ## Links. The
// model proposes nothing here (no hallucinated entities); the strong-tier page
// rewrite fills the page later.
//
// Alias = the hint lowercased/trimmed with whitespace runs collapsed to
// dashes. When that alias already resolves to a node (a natural key or an
// earlier promotion already owns it), no new node is created — the hint is
// simply marked promoted to the existing node id. Created nodes commit once per
// run ("memory(promote): N concept entities") and mirror into the index;
// maxCreate bounds the number of NEW nodes created per run (<= 0 = unbounded).
// Returns the count of concept entities created.
func PromoteConcepts(v *Vault, database *db.DB, minEpisodes, maxCreate int) (int, error) {
	hints, err := database.ListPromotableHints(minEpisodes)
	if err != nil {
		return 0, err
	}

	// promotion pairs a hint with the node id it resolved/was created into, so
	// the hint rows are stamped only after the node is safely committed+indexed.
	type promotion struct{ hint, nodeID string }
	var (
		nodes      []Node
		ids        []string
		promotions []promotion
		created    int
	)
	for _, h := range hints {
		if maxCreate > 0 && created >= maxCreate {
			break
		}
		alias := conceptAlias(h.Hint)
		if alias == "" {
			continue
		}
		if existingID, lerr := database.LookupMemoryAlias(alias); lerr == nil {
			// Collision: an existing node already owns this alias. Point the
			// hint at it and create nothing.
			promotions = append(promotions, promotion{h.Hint, existingID})
			continue
		} else if !errors.Is(lerr, sql.ErrNoRows) {
			return created, fmt.Errorf("memory: promote lookup %q: %w", alias, lerr)
		}

		n := Node{
			ID:      NewID("entity"),
			Type:    "entity",
			Tier:    "long",
			Status:  "active",
			Title:   h.Hint,
			Aliases: []string{alias},
			Body:    entitySkeletonBody(h.Hint, ""),
		}
		for _, epID := range h.EpisodeIDs {
			n.Body = appendToLinks(n.Body, "- [["+epID+"]]\n")
		}
		nodes = append(nodes, n)
		ids = append(ids, n.ID)
		promotions = append(promotions, promotion{h.Hint, n.ID})
		created++
	}

	if len(nodes) > 0 {
		msg := CommitMsg{
			Op:      "promote",
			Summary: fmt.Sprintf("%d concept entities", len(nodes)),
			Cause:   "promote",
			NodeIDs: ids,
		}
		if _, err := v.WriteNodes(nodes, msg); err != nil {
			return 0, err
		}
		now := time.Now().UTC().Format(time.RFC3339)
		mem := newOwnerEditedMemo(v)
		for _, n := range nodes {
			if err := upsertIndexNode(database, mem.lookup, n, now); err != nil {
				return 0, err
			}
		}
	}

	// Stamp hints promoted only now — after the concept node is in the index —
	// so a promoted hint always points at a resolvable node.
	for _, pr := range promotions {
		if err := database.MarkHintPromoted(pr.hint, pr.nodeID); err != nil {
			return created, err
		}
	}
	return created, nil
}

// conceptAlias normalizes a hint into its concept-entity alias: lowercased,
// trimmed, whitespace runs collapsed to single dashes (so "credit card" →
// "credit-card", "HSM" → "hsm"). Recorded hints are already lower/trimmed;
// this is idempotent on them.
func conceptAlias(hint string) string {
	return strings.Join(strings.Fields(strings.ToLower(hint)), "-")
}
