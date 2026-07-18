package memory

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"regexp"
	"strings"
	"time"

	"watchtower/internal/db"
)

var linksHeadingRe = regexp.MustCompile(`(?m)^## Links[ \t]*$`)

// Merge collapses a duplicate node into its canonical twin: the loser file is
// rewritten as a tombstone stub redirecting to the winner, the loser's
// aliases move to the winner (frontmatter and index), and the winner body
// gains a "merged from" link. Exactly one vault commit (op "merge"); the
// index is updated in the same call. Incoming [[loser]] links are NOT
// rewritten — the resolver chases the redirect (lazy repair by later page
// rewrites). Merging a tombstone, into a tombstone, into itself, or with an
// unknown ID is an error and writes nothing.
func Merge(v *Vault, database *db.DB, loserID, winnerID string) error {
	if loserID == winnerID {
		return fmt.Errorf("memory: cannot merge %s into itself", loserID)
	}
	loser, err := readMergeSide(v, loserID, "loser")
	if err != nil {
		return err
	}
	winner, err := readMergeSide(v, winnerID, "winner")
	if err != nil {
		return err
	}

	// Move aliases, deduplicating case-insensitively (memory_aliases is
	// COLLATE NOCASE — a duplicate would break the index upsert); the
	// winner's casing wins.
	seen := make(map[string]bool, len(winner.Aliases))
	for _, a := range winner.Aliases {
		seen[strings.ToLower(a)] = true
	}
	for _, a := range loser.Aliases {
		if !seen[strings.ToLower(a)] {
			winner.Aliases = append(winner.Aliases, a)
			seen[strings.ToLower(a)] = true
		}
	}
	winner.Body = appendMergedFrom(winner.Body, loserID)

	stub := Node{
		ID:         loser.ID,
		Type:       loser.Type,
		Tier:       loser.Tier,
		Status:     "tombstone",
		RedirectTo: winnerID,
		Body:       "Merged into [[" + winnerID + "]].\n",
	}

	msg := CommitMsg{
		Op:      "merge",
		Summary: fmt.Sprintf("merge %s into %s", loserID, winnerID),
		Cause:   "merge",
		NodeIDs: []string{loserID, winnerID},
	}
	if _, err := v.WriteNodes([]Node{stub, winner}, msg); err != nil {
		return err
	}

	// Mirror both nodes into the index. Loser first: its alias rows must be
	// cleared before the same aliases are inserted for the winner.
	now := time.Now().UTC().Format(time.RFC3339)
	mem := newOwnerEditedMemo(v)
	for _, n := range []Node{stub, winner} {
		if err := upsertIndexNode(database, mem.lookup, n, now); err != nil {
			return err
		}
	}
	return nil
}

// readMergeSide loads one side of a merge, rejecting unknown IDs and
// tombstones before anything is written.
func readMergeSide(v *Vault, id, role string) (Node, error) {
	n, err := v.ReadNode(id)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return Node{}, fmt.Errorf("memory: merge %s: %w: %q", role, ErrNotFound, id)
		}
		return Node{}, fmt.Errorf("memory: merge %s: %w", role, err)
	}
	if n.Status == "tombstone" {
		return Node{}, fmt.Errorf("memory: merge %s %s is a tombstone", role, id)
	}
	return n, nil
}

// appendMergedFrom adds the merged-from link to the winner's "## Links"
// section.
func appendMergedFrom(body, loserID string) string {
	return appendToLinks(body, "- merged from [["+loserID+"]]\n")
}

// appendToLinks adds a line as the first entry of the "## Links" section, or
// appends it to the end of the body when the section is absent. line must be
// newline-terminated. A line already present in the body verbatim is not
// added again — a re-extracted window (MEM-04 re-processing) or a repeated
// merge must not duplicate Links entries.
func appendToLinks(body, line string) string {
	for _, existing := range strings.Split(body, "\n") {
		if existing == strings.TrimSuffix(line, "\n") {
			return body
		}
	}
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

// upsertIndexNode mirrors a just-written node into the SQLite index, hashing
// the same rendered bytes that WriteNodes put on disk (so a later Reconcile
// sees the file as unchanged). ownerEdited resolves the owner-touch signal
// for computeNodeImportance: every real caller of this function loops over
// more than one node per invocation (second whole-branch review follow-up,
// 2026-07-19, MEM-16 addendum — the "single-node, nothing to memoize" case
// 5d-ii's design assumed does not exist in production code), so every caller
// passes a per-call ownerEditedMemo's lookup method, never v.OwnerEdited
// directly.
func upsertIndexNode(database *db.DB, ownerEdited func(rel string) (bool, error), n Node, indexedAt string) error {
	rel, err := nodeRelPath(n.ID)
	if err != nil {
		return err
	}
	importance, err := computeNodeImportance(database, ownerEdited, n, rel)
	if err != nil {
		return fmt.Errorf("memory: computing importance for %s: %w", n.ID, err)
	}
	sum := sha256.Sum256(n.Render())
	row := db.MemoryNodeRow{
		ID:              n.ID,
		Type:            n.Type,
		Tier:            n.Tier,
		Status:          n.Status,
		RedirectTo:      n.RedirectTo,
		Title:           n.Title,
		Path:            rel,
		ContentHash:     hex.EncodeToString(sum[:]),
		IndexedAt:       indexedAt,
		Subject:         n.Subject,    // file-derived (belief-only; "" otherwise), see 00019
		Confidence:      n.Confidence, // file-derived (belief-only; 0 otherwise), see 00019
		ImportanceScore: importance,
	}
	if err := database.UpsertMemoryNode(row, n.Body, n.Aliases, provenanceRows(n, nil)...); err != nil {
		return fmt.Errorf("memory: index %s: %w", n.ID, err)
	}
	return nil
}
