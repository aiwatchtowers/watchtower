package kb

import (
	"context"
	"database/sql"
	"fmt"

	"watchtower/internal/db"
)

// drainDirty re-renders every document of src that kb_dirty marks: a source
// row was edited in place or deleted, which moves no change cursor the
// source's Changed can see (migration 00136's triggers write the marks). A
// source document that no longer exists renders as nil, so the key is
// deleted from the index like any gone document — a purge or an FK cascade
// that left a mark behind is no error and the row is removed with it.
//
// Each batch is rendered outside any transaction; one short transaction then
// stores it and deletes the marks by the gen read with them, so a key marked
// again during its render keeps its row and is drained on a later pass. It
// returns false (no error) when overBudget stopped it before the table was
// empty; a key marked again while this call runs is left for the next run, so
// a source that never stops writing marks cannot hold the call; the budget is checked only after a batch, never before the first.
func drainDirty(ctx context.Context, d *db.DB, src Source, overBudget func() bool, st *Stats) (bool, error) {
	name := src.Name()
	after := "" // keyset cursor: a key re-marked behind it waits for the next pass
	for {
		keys, gens, err := loadDirty(ctx, d, name, after)
		if err != nil {
			return false, err
		}
		if len(keys) == 0 {
			return true, nil
		}
		rendered, err := buildBatch(ctx, d, src, keys)
		if err != nil {
			return false, err
		}
		after = keys[len(keys)-1]
		docs := prepareBatch(rendered)
		var written, deleted int
		err = withTx(ctx, d, func(tx *sql.Tx) error {
			var err error
			if written, deleted, err = storeBatch(ctx, tx, keys, docs); err != nil {
				return err
			}
			for i, key := range keys {
				if _, err := tx.ExecContext(ctx, `DELETE FROM kb_dirty WHERE source = ? AND key = ? AND gen = ?`, name, key, gens[i]); err != nil {
					return fmt.Errorf("kb: clearing dirty mark %s: %w", key, err)
				}
			}
			return nil
		})
		if err != nil {
			return false, err
		}
		st.Written += written
		st.Deleted += deleted
		if overBudget() {
			return false, nil
		}
	}
}

func loadDirty(ctx context.Context, d *db.DB, source, after string) (keys []string, gens []int64, err error) {
	rows, err := d.QueryContext(ctx, `SELECT key, gen FROM kb_dirty WHERE source = ? AND key > ? ORDER BY key LIMIT ?`, source, after, batchSize)
	if err != nil {
		return nil, nil, fmt.Errorf("kb: reading dirty marks: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var k string
		var g int64
		if err := rows.Scan(&k, &g); err != nil {
			return nil, nil, err
		}
		keys = append(keys, k)
		gens = append(gens, g)
	}
	return keys, gens, rows.Err()
}
