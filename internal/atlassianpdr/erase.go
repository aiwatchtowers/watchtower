package atlassianpdr

import (
	"context"
	"database/sql"
	"fmt"

	"watchtower/internal/db"
)

// EraseClosed erases what Atlassian told Watchtower about the closed
// accounts ids on Jira account accountID (db.EraseAtlassianPeople) in one
// write transaction: all or nothing, and a repeat changes nothing more. What
// to blank and re-render is read before the transaction opens, so it holds
// the write lock only for the writes.
func EraseClosed(ctx context.Context, d *db.DB, accountID int64, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	plan, err := d.PlanAtlassianErase(ctx, accountID, ids)
	if err != nil {
		return err
	}
	if err := d.WithTx(func(tx *sql.Tx) error { return d.EraseAtlassianPeople(ctx, tx, accountID, ids, plan) }); err != nil {
		return fmt.Errorf("erasing closed atlassian accounts of jira account %d: %w", accountID, err)
	}
	return nil
}
