package memory

import (
	"database/sql"
	"errors"
	"fmt"

	"watchtower/internal/db"
)

// ErrNotFound is returned by Resolve when a ref matches neither a canonical
// node ID nor any alias in the index.
var ErrNotFound = errors.New("memory: node not found")

// Resolve turns any ref — canonical node ID, alias (case-insensitive; natural
// keys like "C0123ABC" or "situation:42"), or a tombstoned old ID — into the
// final canonical node. Redirects are chased through tombstone redirect_to
// chains with a cycle guard; the returned Node carries the final canonical ID
// in Node.ID. Lookups go through the SQLite index; node content is read from
// the vault (the source of truth).
func Resolve(v *Vault, database *db.DB, ref string) (Node, error) {
	id := ref
	if _, err := database.GetMemoryNode(ref); err != nil {
		if !errors.Is(err, sql.ErrNoRows) {
			return Node{}, fmt.Errorf("memory: resolve %q: %w", ref, err)
		}
		aliasID, aliasErr := database.LookupMemoryAlias(ref)
		if errors.Is(aliasErr, sql.ErrNoRows) {
			return Node{}, fmt.Errorf("%w: %q", ErrNotFound, ref)
		}
		if aliasErr != nil {
			return Node{}, fmt.Errorf("memory: resolve %q: %w", ref, aliasErr)
		}
		id = aliasID
	}

	seen := map[string]bool{}
	for {
		if seen[id] {
			return Node{}, fmt.Errorf("memory: redirect cycle at %s while resolving %q", id, ref)
		}
		seen[id] = true

		n, err := v.ReadNode(id)
		if err != nil {
			return Node{}, err
		}
		if n.Status == "tombstone" && n.RedirectTo != "" {
			id = n.RedirectTo
			continue
		}
		return n, nil
	}
}
