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

// RetentionInputs are the file-derived signals behind a node's retention score.
// Access stats are deliberately absent: the counters are write-dead in
// production (spec §Retention), so they never enter the formula in Phase 3.
type RetentionInputs struct {
	LastEventAgeDays float64 // age of the newest provenance event, in days
	LinksIn          int     // live nodes linking to this one
	SituationOrigin  bool    // node carries a situation:<id> alias
	OwnerTouched     bool    // file was ever touched by a memory(owner-edit) commit
}

// Retention constants live in code, not config (mirrors belief_math.go): one
// auditable place for the eviction math.
const (
	retentionRecencyHorizonDays = 180.0 // recency decays to the floor over this span
	retentionRecencyFloor       = 0.25  // ancient nodes keep a little recency so links-in still protect them
	retentionSituationBonus     = 1.0
	retentionOwnerBonus         = 2.0 // owner-touched outweighs the situation bonus
)

// RetentionScore is the pure retention formula: recency(last event) ×
// importance, where importance = links-in + situation-origin bonus +
// owner-touch bonus. A cold, unreferenced, un-touched episode scores 0
// (importance 0) and is always evictable; links-in or an owner edit lift it
// above a positive threshold. Side-effect free and exhaustively unit-tested.
func RetentionScore(in RetentionInputs) float64 {
	recency := 1.0 - in.LastEventAgeDays/retentionRecencyHorizonDays
	if recency < retentionRecencyFloor {
		recency = retentionRecencyFloor
	}
	if recency > 1.0 {
		recency = 1.0
	}
	importance := float64(in.LinksIn)
	if in.SituationOrigin {
		importance += retentionSituationBonus
	}
	if in.OwnerTouched {
		importance += retentionOwnerBonus
	}
	return recency * importance
}

// EvictEpisodes collapses cold closed long-tier episodes into per-channel-per-
// month rollups (MEM-07). An episode is evicted when it is closed + long-tier,
// its newest provenance event is older than olderThanDays, and its retention
// score is below scoreThreshold. Each evicted episode contributes one gist line
// (title + outcome one-liner + ALL provenance refs carried VERBATIM) to the
// (channel, month) rollup (sum_*, tier long); its file becomes a tombstone
// redirecting to the rollup and its aliases move to the rollup, so the resolver
// and old [[ep_*]] links keep working and provenance never thins. A second
// eviction into the same channel-month appends to the existing rollup rather
// than duplicating it. One "memory(evict)" commit per run; maxEvict caps
// evictions per run (<= 0 = unbounded). Entities and beliefs are never evicted.
func EvictEpisodes(v *Vault, database *db.DB, olderThanDays int, scoreThreshold float64, maxEvict int) (evicted int, err error) {
	rows, err := database.ListMemoryNodes()
	if err != nil {
		return 0, err
	}
	now := time.Now()

	rollups := map[string]*Node{} // "channel|month" → rollup being built this run
	var order []string            // deterministic rollup emission order
	var tombstones []Node

	for _, row := range rows {
		if maxEvict > 0 && evicted >= maxEvict {
			break
		}
		if row.Type != "episode" || row.Tier != "long" || row.Status != "closed" {
			continue
		}
		n, rerr := v.ReadNode(row.ID)
		if rerr != nil {
			return evicted, rerr
		}
		refs := parseProvenance(n.Body)
		if len(refs) == 0 {
			continue // no provenance → nothing to roll into, nothing to preserve
		}
		lastTS, ok := lastEventTS(refs)
		if !ok {
			continue
		}
		ageDays := now.Sub(time.Unix(int64(lastTS), 0)).Hours() / 24
		if ageDays < float64(olderThanDays) {
			continue // inside the retention window
		}

		linksIn, lerr := database.CountMemoryLinksIn(n.ID)
		if lerr != nil {
			return evicted, lerr
		}
		rel, rerr := nodeRelPath(n.ID)
		if rerr != nil {
			return evicted, rerr
		}
		ownerTouched, oerr := v.OwnerEdited(rel)
		if oerr != nil {
			return evicted, oerr
		}
		score := RetentionScore(RetentionInputs{
			LastEventAgeDays: ageDays,
			LinksIn:          linksIn,
			SituationOrigin:  hasSituationAlias(n.Aliases),
			OwnerTouched:     ownerTouched,
		})
		if score >= scoreThreshold {
			continue // still warm enough — keep the episode
		}

		channelID := refs[0].ChannelID
		month := time.Unix(int64(lastTS), 0).UTC().Format("2006-01")
		key := channelID + "|" + month
		roll := rollups[key]
		if roll == nil {
			roll, rerr = loadOrCreateRollup(v, database, channelID, month)
			if rerr != nil {
				return evicted, rerr
			}
			rollups[key] = roll
			order = append(order, key)
		}
		roll.Body = appendGist(roll.Body, gistLine(n, refs))
		roll.Aliases = mergeAliases(roll.Aliases, n.Aliases)

		tombstones = append(tombstones, Node{
			ID:         n.ID,
			Type:       n.Type,
			Tier:       n.Tier,
			Status:     "tombstone",
			RedirectTo: roll.ID,
			Body:       "Evicted into [[" + roll.ID + "]].\n",
		})
		evicted++
	}

	if evicted == 0 {
		return 0, nil
	}

	// Commit tombstones + rollups as one commit, then mirror to the index —
	// tombstones first so their alias rows are cleared before a rollup claims
	// the moved aliases (the same loser-first ordering Merge uses).
	nodes := make([]Node, 0, len(tombstones)+len(order))
	ids := make([]string, 0, len(tombstones)+len(order))
	for _, t := range tombstones {
		nodes = append(nodes, t)
		ids = append(ids, t.ID)
	}
	for _, key := range order {
		nodes = append(nodes, *rollups[key])
		ids = append(ids, rollups[key].ID)
	}
	msg := CommitMsg{
		Op:      "evict",
		Summary: fmt.Sprintf("%d episodes into %d rollup(s)", evicted, len(order)),
		Cause:   "evict",
		NodeIDs: ids,
	}
	if _, err := v.WriteNodes(nodes, msg); err != nil {
		return 0, err
	}
	nowStr := time.Now().UTC().Format(time.RFC3339)
	for _, t := range tombstones {
		if err := upsertIndexNode(database, t, nowStr); err != nil {
			return evicted, err
		}
	}
	for _, key := range order {
		if err := upsertIndexNode(database, *rollups[key], nowStr); err != nil {
			return evicted, err
		}
	}
	return evicted, nil
}

// loadOrCreateRollup returns the existing (channel, month) rollup — resolved by
// its stable "rollup:<channel>:<month>" alias so a later run appends rather
// than duplicating — or a fresh sum_* rollup node when none exists yet.
func loadOrCreateRollup(v *Vault, database *db.DB, channelID, month string) (*Node, error) {
	alias := "rollup:" + channelID + ":" + month
	if existingID, err := database.LookupMemoryAlias(alias); err == nil {
		n, rerr := v.ReadNode(existingID)
		if rerr != nil {
			return nil, rerr
		}
		return &n, nil
	} else if !errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("memory: evict rollup lookup %q: %w", alias, err)
	}
	title := month + " " + channelID
	n := Node{
		ID:      NewID("rollup"),
		Type:    "rollup",
		Tier:    "long",
		Status:  "active",
		Title:   title,
		Aliases: []string{alias},
		Body:    "# " + title + "\n\n## Rollup\n",
	}
	return &n, nil
}

// gistLine renders one evicted episode's rollup entry: title + outcome
// one-liner + every provenance ref verbatim (MEM-07 — no ref may be dropped).
func gistLine(n Node, refs []episodeRef) string {
	var b strings.Builder
	b.WriteString("- " + strings.ReplaceAll(n.Title, "\n", " "))
	if out := outcomeExcerpt(n.Body); out != "" {
		b.WriteString(" — " + out)
	}
	b.WriteString(" [")
	for i, r := range refs {
		if i > 0 {
			b.WriteString(", ")
		}
		b.WriteString(r.ChannelID + " " + r.TS)
	}
	b.WriteString("]\n")
	return b.String()
}

// appendGist appends a gist line to the end of a rollup body.
func appendGist(body, line string) string {
	if body != "" && !strings.HasSuffix(body, "\n") {
		body += "\n"
	}
	return body + line
}

// outcomeExcerpt returns the first non-empty line of the "## Outcome" section.
func outcomeExcerpt(body string) string {
	inOutcome := false
	for _, line := range strings.Split(body, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "## ") {
			inOutcome = trimmed == "## Outcome"
			continue
		}
		if inOutcome && trimmed != "" {
			return trimmed
		}
	}
	return ""
}

// hasSituationAlias reports whether any alias marks a situation origin.
func hasSituationAlias(aliases []string) bool {
	for _, a := range aliases {
		if strings.HasPrefix(a, "situation:") {
			return true
		}
	}
	return false
}

// lastEventTS returns the newest parseable provenance ts across the refs.
func lastEventTS(refs []episodeRef) (float64, bool) {
	var newest float64
	ok := false
	for _, r := range refs {
		ts, err := strconv.ParseFloat(r.TS, 64)
		if err != nil {
			continue
		}
		if !ok || ts > newest {
			newest = ts
			ok = true
		}
	}
	return newest, ok
}

// mergeAliases appends add's aliases to into, deduplicating case-insensitively
// (memory_aliases is COLLATE NOCASE); into's casing wins.
func mergeAliases(into, add []string) []string {
	seen := make(map[string]bool, len(into))
	for _, a := range into {
		seen[strings.ToLower(a)] = true
	}
	for _, a := range add {
		if !seen[strings.ToLower(a)] {
			into = append(into, a)
			seen[strings.ToLower(a)] = true
		}
	}
	return into
}
