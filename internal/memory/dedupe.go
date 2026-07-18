package memory

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
)

// provenanceHeadingRe matches the "## Provenance" section heading.
var provenanceHeadingRe = regexp.MustCompile(`(?m)^## Provenance[ \t]*$`)

// DedupeEpisodes is the first real consumer of Merge: a mechanical pass that
// collapses retry-duplicated episodes (the failed-window re-extraction the E2E
// documented). Candidacy is keyed on PROVENANCE-REF OVERLAP within one channel,
// never on title similarity — the E2E's duplicate pairs had differing titles,
// so a title heuristic is empirically dead; a shared channel_id+ts ref is the
// reliable signal.
//
// A pair is merged when both episodes are active short-tier, belong to the same
// channel, and share at least one provenance ref. A shared channel_id+ts ref
// already implies overlapping time (MEM-01 guarantees every ref is a real,
// parseable message ts), so no separate time-range check is needed. The older
// id wins (ULIDs sort by creation time, so the lexicographically smaller id is
// older): Merge(loser=newer, winner=older) tombstones the newer and the
// resolver chases it back. Closed/long/tombstone episodes are out of scope.
//
// This pass is Slack-SCOPED: a Gmail episode carries a unique mail:<message_id>
// as its first provenance ref, so two runs' extractions of one thread never
// share a bucket here. Gmail thread idempotency is instead guaranteed at WRITE
// time by the stable "gmailthread:<thread_id>" alias (buildGmailEpisodeNodes
// updates the existing episode in place), so a mail-ref episode is deliberately
// skipped — it can never be a retry duplicate needing a mechanical merge.
// maxMerges caps merges per run; <= 0 means unlimited. A per-node read failure
// is skipped-and-logged (the package quarantine convention) so one corrupted
// candidate never stops the pass.
func DedupeEpisodes(v *Vault, database *db.DB, maxMerges int, logf func(string, ...any)) (merged int, err error) {
	rows, err := database.ListMemoryNodes()
	if err != nil {
		return 0, err
	}
	// Situation mirrors are excluded entirely — winner AND loser (M2): two
	// situations can share an inbox signal, so their mirrors legitimately share
	// a provenance ref while being DIFFERENT stories; a merge makes the
	// situations-ingest refresh ping-pong the merged node's content every run.
	// A mirror's identity is its situation: alias, not ref overlap (the
	// gmailthread:/calevent: alias-keyed idempotency precedent).
	sitMirrors, err := database.SituationMirrorNodeIDs()
	if err != nil {
		return 0, err
	}
	mem := newOwnerEditedMemo(v)

	// Collect candidate episodes grouped by channel. ListMemoryNodes already
	// orders by id, so within each channel the slice stays oldest-first.
	byChannel := make(map[string][]epCandidate)
	for _, row := range rows {
		if row.Type != "episode" || row.Tier != "short" || row.Status != "active" {
			continue
		}
		if sitMirrors[row.ID] {
			continue // situation mirror — alias-keyed identity, never dedupe-merged (M2)
		}
		n, rerr := v.ReadNode(row.ID)
		if rerr != nil {
			logf("memory: dedupe: read %s: %v (skipped)", row.ID, rerr)
			continue
		}
		refs := parseProvenance(n.Body)
		if len(refs) == 0 {
			continue // no provenance key to match on
		}
		ch := refs[0].ChannelID
		if schemeOf(ch) == "mail" {
			continue // Gmail thread idempotency is alias-keyed, not dedupe-keyed (Slack-scoped)
		}
		byChannel[ch] = append(byChannel[ch], newEpCandidate(row.ID, refs))
	}

	consumed := make(map[string]bool) // ids already tombstoned this run
	for _, eps := range byChannel {
		for i := range eps {
			if consumed[eps[i].id] {
				continue
			}
			for j := i + 1; j < len(eps); j++ {
				if maxMerges > 0 && merged >= maxMerges {
					return merged, nil
				}
				if consumed[eps[j].id] {
					continue
				}
				if !eps[i].sharesRef(eps[j]) {
					continue
				}
				// i is older (smaller id) → winner; j is newer → loser. Union the
				// loser-only provenance refs into the winner BEFORE the merge (the
				// tombstone stub Merge writes for the loser drops its body), so a
				// partial-overlap merge never thins provenance (MEM-07).
				if err := unionProvenance(v, database, mem.lookup, eps[i].id, eps[j].id); err != nil {
					return merged, err
				}
				if err := Merge(v, database, eps[j].id, eps[i].id); err != nil {
					return merged, err
				}
				// Fold the loser's refs into the winner's in-memory candidate so a
				// later candidate that overlaps ONLY through the loser still merges
				// in this same run (A<B<C where C shares only B's ref → all merge).
				for k := range eps[j].refs {
					eps[i].refs[k] = true
				}
				consumed[eps[j].id] = true
				merged++
			}
		}
	}
	return merged, nil
}

// unionProvenance appends the loser's provenance refs that the winner does not
// already carry to the winner's ## Provenance section and commits the winner, so
// a partial-overlap dedupe merge never loses a ref (MEM-07: provenance never
// thins). Identical ref sets — the common retry-duplicate case — are a no-op:
// the winner already holds every ref, so nothing is written or committed.
func unionProvenance(v *Vault, database *db.DB, ownerEdited func(rel string) (bool, error), winnerID, loserID string) error {
	winner, err := v.ReadNode(winnerID)
	if err != nil {
		return err
	}
	loser, err := v.ReadNode(loserID)
	if err != nil {
		return err
	}
	have := make(map[string]bool)
	for _, r := range parseProvenance(winner.Body) {
		have[r.ChannelID+" "+r.TS] = true
	}
	var missing []episodeRef
	for _, r := range parseProvenance(loser.Body) {
		key := r.ChannelID + " " + r.TS
		if !have[key] {
			have[key] = true
			missing = append(missing, r)
		}
	}
	if len(missing) == 0 {
		return nil
	}
	for _, r := range missing {
		winner.Body = appendToSection(winner.Body, provenanceHeadingRe, "## Provenance", "- "+r.ChannelID+" "+r.TS+"\n")
	}
	msg := CommitMsg{
		Op:      "dedupe",
		Summary: fmt.Sprintf("union %d provenance ref(s) into %s", len(missing), winnerID),
		Cause:   "dedupe",
		NodeIDs: []string{winnerID},
	}
	if _, err := v.WriteNodes([]Node{winner}, msg); err != nil {
		return err
	}
	return upsertIndexNode(database, ownerEdited, winner, time.Now().UTC().Format(time.RFC3339))
}

// epCandidate is one episode's dedupe key: its provenance ref set within a
// single channel. A shared ref is the whole merge signal (MEM-01 guarantees the
// ts is a real message time), so no separate time range is tracked.
type epCandidate struct {
	id   string
	refs map[string]bool // "<channel_id> <ts>" keys
}

func newEpCandidate(id string, refs []episodeRef) epCandidate {
	c := epCandidate{id: id, refs: make(map[string]bool, len(refs))}
	for _, r := range refs {
		c.refs[r.ChannelID+" "+r.TS] = true
	}
	return c
}

// sharesRef reports whether the candidates share at least one channel_id+ts
// provenance ref — the merge key.
func (c epCandidate) sharesRef(o epCandidate) bool {
	// Iterate the smaller set for cheapness.
	a, b := c.refs, o.refs
	if len(b) < len(a) {
		a, b = b, a
	}
	for k := range a {
		if b[k] {
			return true
		}
	}
	return false
}

// parseProvenance extracts the channel_id+ts refs from a node's "## Provenance"
// section (the "- <channel_id> <ts>" lines episodeBody renders). Sibling of
// Node.Links; the resolver-visible complement to the frontmatter refs.
func parseProvenance(body string) []episodeRef {
	var refs []episodeRef
	inProv := false
	for _, line := range strings.Split(body, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "## ") {
			inProv = trimmed == "## Provenance"
			continue
		}
		if !inProv {
			continue
		}
		item := strings.TrimSpace(strings.TrimPrefix(trimmed, "-"))
		if item == trimmed { // not a "- " bullet
			continue
		}
		fields := strings.Fields(item)
		if len(fields) != 2 {
			continue
		}
		refs = append(refs, episodeRef{ChannelID: fields[0], TS: fields[1]})
	}
	return refs
}

// provenanceRows builds the db-layer memory_provenance index rows for a node
// from its ## Provenance section — the single parse site the derived
// provenance index flows through (parseProvenance → classify scheme →
// decode ts), keeping the db layer a dumb store (one parse site in memory,
// one write site in db.UpsertMemoryNode, one transaction). Each ref is
// classified by schemeOf (a bare Slack channel_id is scheme "", mail:/cal:/
// chat:/act: carry their prefix) and its ts decoded to a unix float for
// windowed lookup; a ref whose ts is not numeric cannot be windowed and is
// skipped (logged when logf is non-nil). Refs are deduped by
// (channel_id, ts_raw) so the wholesale insert cannot collide on the
// memory_provenance primary key. A node with no ## Provenance section (every
// non-episode/rollup type) yields nil.
func provenanceRows(n Node, logf func(string, ...any)) []db.ProvenanceRow {
	refs := parseProvenance(n.Body)
	if len(refs) == 0 {
		return nil
	}
	seen := make(map[string]bool, len(refs))
	var rows []db.ProvenanceRow
	for _, r := range refs {
		key := r.ChannelID + "\x00" + r.TS
		if seen[key] {
			continue
		}
		seen[key] = true
		tsUnix, err := strconv.ParseFloat(strings.TrimSpace(r.TS), 64)
		if err != nil {
			if logf != nil {
				logf("memory: provenance ref %s %s on %s skipped (non-numeric ts, not windowable)", r.ChannelID, r.TS, n.ID)
			}
			continue
		}
		rows = append(rows, db.ProvenanceRow{
			NodeID:    n.ID,
			Scheme:    schemeOf(r.ChannelID),
			ChannelID: r.ChannelID,
			TSRaw:     r.TS,
			TSUnix:    tsUnix,
		})
	}
	return rows
}
