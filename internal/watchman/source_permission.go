package watchman

import (
	"context"
	"strconv"

	"watchtower/internal/db"
)

// permissionSource learns from permission prompts the owner allowed or
// denied: situation = the tool and its (redacted) input summary.
type permissionSource struct{ skips }

func (*permissionSource) Name() string { return SourcePermission }

func (s *permissionSource) Next(ctx context.Context, d *db.DB, workbenchID int64, cur string, limit int) ([]db.WatchmanPrecedent, string, bool, error) {
	if err := ctx.Err(); err != nil {
		return nil, cur, false, err
	}
	rows, next, done, err := walk(cur, limit, func(from *db.WatchmanMark, older bool, n int) ([]db.WatchmanPermissionRow, error) {
		return d.WatchmanPermissionDecisions(workbenchID, from, older, n)
	}, func(r db.WatchmanPermissionRow) db.WatchmanMark { return r.Mark })
	if err != nil {
		return nil, cur, false, err
	}
	out := make([]db.WatchmanPrecedent, 0, len(rows))
	for _, r := range rows {
		if r.Mark.At == "" {
			s.skip(SourcePermission, strconv.FormatInt(r.ID, 10), errNoStamp)
			continue
		}
		at, err := decidedAt(r.Mark)
		if err != nil {
			return nil, cur, false, err
		}
		choice := "deny"
		if r.Status == db.PermissionAllowed {
			choice = "allow"
		}
		out = append(out, db.WatchmanPrecedent{
			WorkbenchID: workbenchID, Source: SourcePermission, SourceKey: strconv.FormatInt(r.ID, 10),
			Category: CategoryPermission, Situation: clean(joinNonEmpty("\n", "Tool: "+r.ToolName, r.Summary)),
			Choice: choice, DecidedAt: at, Weight: 1,
		})
	}
	return out, next, done, nil
}
