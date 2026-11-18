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
		flags := permissionFlags(permissionAskOf(r))
		out = append(out, db.WatchmanPrecedent{
			WorkbenchID: workbenchID, Source: SourcePermission, SourceKey: strconv.FormatInt(r.ID, 10),
			Category: CategoryPermission, Situation: clean(joinNonEmpty("\n", "Tool: "+r.ToolName, r.Summary)),
			Choice: choice, DecidedAt: at, Weight: 1,
			IsDecision: flags.IsDecision, Parked: flags.Parked,
		})
	}
	return out, next, done, nil
}

// permissionAskOf is the hard-limit table's view of a stored permission
// request: its session folder and worktrees are the places it may touch.
func permissionAskOf(r db.WatchmanPermissionRow) PermissionAsk {
	return PermissionAsk{
		Tool: r.ToolName, Summary: r.Summary, SummaryClipped: r.SummaryClipped, WorkbenchFolder: r.WorkbenchFolder,
		Worktrees: append([]string{r.SessionFolder}, r.Worktrees...),
		// PRBase stays nil: no row the writers produce maps a PR number to its
		// base branch ('into:' rows carry no pr_number), so every `gh pr merge`
		// is parked.
	}
}
