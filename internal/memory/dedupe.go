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
// channel, have overlapping time ranges, and share at least one provenance ref.
// The older id wins (ULIDs sort by creation time, so the lexicographically
// smaller id is older): Merge(loser=newer, winner=older) tombstones the newer
// and the resolver chases it back. Closed/long/tombstone episodes are out of
// scope. maxMerges caps merges per run; <= 0 means unlimited.
func DedupeEpisodes(v *Vault, database *db.DB, maxMerges int) (merged int, err error) {
	rows, err := database.ListMemoryNodes()
	if err != nil {
		return 0, err
	}

	// Collect candidate episodes grouped by channel. ListMemoryNodes already
	// orders by id, so within each channel the slice stays oldest-first.
	byChannel := make(map[string][]epCandidate)
	for _, row := range rows {
		if row.Type != "episode" || row.Tier != "short" || row.Status != "active" {
			continue
		}
		n, rerr := v.ReadNode(row.ID)
		if rerr != nil {
			return merged, rerr
		}
		refs := parseProvenance(n.Body)
		if len(refs) == 0 {
			continue // no provenance key to match on
		}
		ch := refs[0].ChannelID
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
				if !eps[i].overlaps(eps[j]) || !eps[i].sharesRef(eps[j]) {
					continue
				}
				// i is older (smaller id) → winner; j is newer → loser. Union the
				// loser-only provenance refs into the winner BEFORE the merge (the
				// tombstone stub Merge writes for the loser drops its body), so a
				// partial-overlap merge never thins provenance (MEM-07).
				if err := unionProvenance(v, database, eps[i].id, eps[j].id); err != nil {
					return merged, err
				}
				if err := Merge(v, database, eps[j].id, eps[i].id); err != nil {
					return merged, err
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
func unionProvenance(v *Vault, database *db.DB, winnerID, loserID string) error {
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
	return upsertIndexNode(database, winner, time.Now().UTC().Format(time.RFC3339))
}

// epCandidate is one episode's dedupe key: its provenance ref set and time
// range, all within a single channel.
type epCandidate struct {
	id       string
	refs     map[string]bool // "<channel_id> <ts>" keys
	min, max float64         // ts range across the refs
}

func newEpCandidate(id string, refs []episodeRef) epCandidate {
	c := epCandidate{id: id, refs: make(map[string]bool, len(refs))}
	first := true
	for _, r := range refs {
		c.refs[r.ChannelID+" "+r.TS] = true
		ts, err := strconv.ParseFloat(r.TS, 64)
		if err != nil {
			continue
		}
		if first || ts < c.min {
			c.min = ts
		}
		if first || ts > c.max {
			c.max = ts
		}
		first = false
	}
	return c
}

// overlaps reports whether the two candidates' ts ranges intersect.
func (c epCandidate) overlaps(o epCandidate) bool {
	return c.min <= o.max && o.min <= c.max
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
