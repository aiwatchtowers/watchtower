package cmd

import (
	"context"
	"fmt"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/reviewdiff"
	"watchtower/internal/reviewmap"
	"watchtower/internal/tools"
)

// reviewMapBudget bounds the map's lane walk (tech spec §2.1): past it every
// file falls back to the package grouping and the map says lanes_partial.
// A var for tests.
var reviewMapBudget = 20 * time.Second

// lanesUnreadNote is the map's note when the branch's history could not be
// walked (a head commit pruned since the round was taken, a git failure):
// the chapters are the package grouping.
const lanesUnreadNote = "Lanes: the branch's history could not be read; chapters group files by package."

// laneTitlesUnreadNote is the map's note when the lane titles (board
// targets, Jira summaries) could not be read: lanes carry branch names and
// tags are not checked.
const laneTitlesUnreadNote = "Lanes: ticket titles could not be read; lanes are named by branch."

// laneBaseUnknownNote is the map's note when no default branch exists
// (no origin HEAD, main or master): merges from it cannot be told from lane
// merges, so they may show as lanes.
const laneBaseUnknownNote = "Lanes: no default branch found; merges from it may show as lanes."

var workbenchReviewMapCmd = &cobra.Command{
	Use:   "map",
	Short: "The review's instant map: chapters in reading order, danger signals, lanes (no AI, writes nothing)",
	RunE:  runWorkbenchReviewMap,
}

func init() {
	workbenchReviewMapCmd.Flags().Int64Var(&reviewFlagWorkbench, workbenchFlag, 0, "workbench id")
	workbenchReviewMapCmd.Flags().BoolVar(&reviewFlagJSON, "json", false, "output JSON")
	workbenchReviewMapCmd.Flags().Int64Var(&reviewFlagRound, "round", 0, "review round id")
	workbenchReviewMapCmd.Flags().Int64Var(&reviewFlagSession, "session", 0, "terminal session id: the session's folder as it stands, no round")
	workbenchReviewCmd.AddCommand(workbenchReviewMapCmd)
}

// reviewPlace is what a map is built from: the repository, the tree and its
// base, the commit the tree was taken at ("" = no lanes: a round made
// before head_sha existed), the reviewed branch's name when known, and the
// session whose agent chapters lead the map (0 = none).
type reviewPlace struct {
	Repo       *reviewdiff.Repo
	Tree, Base string
	Head       string
	HeadBranch string
	SessionID  int64
	// Folder is the snapshot folder's root: the overview's run lock is
	// keyed by its real path (tech spec §3.7).
	Folder string
}

// roundReviewPlace is round r's place. The head is the round's own
// head_sha, never the folder's HEAD of today (it may be another history);
// the branch is the round's (a branch-tip round, #1012), else the folder's
// checked-out branch.
func roundReviewPlace(ctx context.Context, repo *reviewdiff.Repo, r *db.ReviewRound) (reviewPlace, error) {
	pl := reviewPlace{Repo: repo, Tree: r.TreeSHA, Base: r.BaseSHA, Head: r.HeadSHA, HeadBranch: r.Branch, Folder: r.FolderRoot}
	if r.SessionID.Valid {
		pl.SessionID = r.SessionID.Int64
	}
	if pl.Head != "" && pl.HeadBranch == "" {
		branch, err := repo.HeadBranch(ctx)
		if err != nil {
			return reviewPlace{}, err
		}
		pl.HeadBranch = branch
	}
	return pl, nil
}

// sessionReviewPlace is session sessionID's folder as it stands, no round:
// the snapshot the session-form overview reads, at the folder's HEAD now.
func sessionReviewPlace(ctx context.Context, d *db.DB, p *db.Workbench, sessionID int64) (reviewPlace, error) {
	snap, err := tools.SnapshotReviewSession(ctx, d, p, sessionID)
	if err != nil {
		return reviewPlace{}, err
	}
	head, err := snap.Repo.HeadCommit(ctx)
	if err != nil {
		return reviewPlace{}, err
	}
	branch, err := snap.Repo.HeadBranch(ctx)
	if err != nil {
		return reviewPlace{}, err
	}
	return reviewPlace{Repo: snap.Repo, Tree: snap.Tree, Base: snap.Base, Head: head, HeadBranch: branch, SessionID: sessionID,
		Folder: snap.Folder}, nil
}

// BuildReviewMap reads the place's diff, the session's agent chapters, the
// workbench's .watchtower/review-map.md and the lanes (within
// reviewMapBudget, the default-branch read included), and builds the map
// (tech spec §2). It writes nothing. A done ctx or a failing diff is an
// error; a lane walk that runs out of budget or cannot read the history
// gives the package grouping and lanes_partial.
func BuildReviewMap(ctx context.Context, d *db.DB, p *db.Workbench, pl reviewPlace) (reviewmap.Map, reviewdiff.Diff, error) {
	deadline := time.Now().Add(reviewMapBudget)
	diff, err := pl.Repo.Diff(ctx, pl.Base, pl.Tree)
	if err != nil {
		return reviewmap.Map{}, reviewdiff.Diff{}, err
	}
	in := reviewmap.Input{Diff: diff, Patterns: reviewmap.LoadPatterns(p.FolderPath)}
	if pl.SessionID != 0 {
		// Every chapter note of the session, whatever its tree_sha: the
		// Desktop's agent chapters (ReviewChangesModel) are the same set, so
		// the agent:<n> keys agree.
		if in.AgentChapters, err = d.ReviewNotes(p.ID, pl.SessionID); err != nil {
			return reviewmap.Map{}, reviewdiff.Diff{}, err
		}
	}
	var notes []string
	if in.Attribution, notes, err = reviewLanes(ctx, d, p, pl, deadline); err != nil {
		return reviewmap.Map{}, reviewdiff.Diff{}, err
	}
	m := reviewmap.Build(in)
	m.Notes = append(m.Notes, notes...)
	return m, diff, nil
}

// mapTitles is the map's title source: DBTitles, remembering whether it
// failed (the attribution then folds the failure into lanes_partial).
type mapTitles struct {
	reviewmap.DBTitles
	failed bool
}

func (t *mapTitles) Titles(branches, jiraKeys []string, boardRefs []int64) (reviewmap.LaneTitles, error) {
	out, err := t.DBTitles.Titles(branches, jiraKeys, boardRefs)
	if err != nil {
		t.failed = true
	}
	return out, err
}

// reviewLanes attributes the place's committed files to lanes, with the
// notes to add to the map. A history git could not walk gives an empty
// partial attribution and lanesUnreadNote; no default branch gives a
// partial attribution and laneBaseUnknownNote; unreadable lane titles give
// laneTitlesUnreadNote. Only a done ctx is an error.
func reviewLanes(ctx context.Context, d *db.DB, p *db.Workbench, pl reviewPlace, deadline time.Time) (reviewmap.Attribution, []string, error) {
	titles := &mapTitles{DBTitles: reviewmap.DBTitles{DB: d, ProjectID: p.ID}}
	a, baseKnown, err := attributeLanes(ctx, pl, titles, deadline)
	if err == nil {
		var notes []string
		if !baseKnown {
			a.Partial = true
			stderrLogf("review map: no default branch (workbench %d, session %d); base syncs not told from lanes", p.ID, pl.SessionID)
			notes = append(notes, laneBaseUnknownNote)
		}
		if titles.failed {
			// No error text (FILES-01): a database message may carry a name.
			stderrLogf("review map: lane titles unreadable (workbench %d, session %d); lanes named by branch", p.ID, pl.SessionID)
			notes = append(notes, laneTitlesUnreadNote)
		}
		return a, notes, nil
	}
	if ctx.Err() != nil {
		return reviewmap.Attribution{}, nil, ctx.Err()
	}
	// No error text (FILES-01): git's message may carry a path.
	stderrLogf("review map: lane walk failed (workbench %d, session %d); package chapters", p.ID, pl.SessionID)
	return reviewmap.Attribution{Partial: true}, []string{lanesUnreadNote}, nil
}

// attributeLanes reads the default branch and walks the lanes, both before
// deadline: a default-branch read past it is an error (package chapters),
// a walk past it is partial. baseKnown is false when the place has a head
// but the repository has no default branch to tell base syncs by.
func attributeLanes(ctx context.Context, pl reviewPlace, titles reviewmap.TitleSource, deadline time.Time) (a reviewmap.Attribution, baseKnown bool, err error) {
	var defaultTip string
	if pl.Head != "" {
		tipCtx, cancel := context.WithDeadline(ctx, deadline)
		defaultTip, err = pl.Repo.DefaultTip(tipCtx)
		cancel()
		if err != nil {
			return reviewmap.Attribution{}, false, err
		}
	}
	a, err = reviewmap.Attribute(ctx, pl.Repo, pl.Base, pl.Head, pl.HeadBranch, defaultTip, titles, time.Until(deadline))
	return a, pl.Head == "" || defaultTip != "", err
}

func runWorkbenchReviewMap(cmd *cobra.Command, _ []string) error {
	if (reviewFlagRound == 0) == (reviewFlagSession == 0) {
		return fmt.Errorf("exactly one of --round and --session is required")
	}
	var (
		database *db.DB
		p        *db.Workbench
		pl       reviewPlace
		ctx      context.Context
		cancel   context.CancelFunc
		err      error
	)
	if reviewFlagRound != 0 {
		var r *db.ReviewRound
		var repo *reviewdiff.Repo
		database, r, repo, ctx, cancel, err = loadRound(cmd)
		if err != nil || r == nil {
			return err
		}
		defer cancel()
		if p, err = workbenchWithFolder(database, reviewFlagWorkbench); err != nil {
			return err
		}
		if pl, err = roundReviewPlace(ctx, repo, r); err != nil {
			return failReview(cmd, err)
		}
	} else {
		if database, p, err = reviewTarget(); err != nil {
			return err
		}
		ctx, cancel = workbenchGitContext(cmd, workbenchReviewBudget)
		defer cancel()
		if pl, err = sessionReviewPlace(ctx, database, p, reviewFlagSession); err != nil {
			return failReview(cmd, err)
		}
	}
	m, _, err := BuildReviewMap(ctx, database, p, pl)
	if err != nil {
		return failReview(cmd, err)
	}
	return writeReview(cmd, reviewEnvelope{OK: true, Map: &m})
}
