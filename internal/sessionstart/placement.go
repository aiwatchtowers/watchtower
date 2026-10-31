package sessionstart

import (
	"context"
	"errors"
	"strings"

	"watchtower/internal/workbenchgit"
)

// Choice is the owner's per-start choice of where a new agent session runs
// (Swift WorktreeChoice).
type Choice string

const (
	ChoiceAuto     Choice = "auto"
	ChoiceFolder   Choice = "folder"
	ChoiceWorktree Choice = "worktree"
)

// Placement is where a new agent session starts: its own worktree, or the
// folder with Note saying why a worktree that was asked for or implied was
// not used ("" = nothing to say).
type Placement struct {
	Worktree bool
	Note     string
}

// WantsWorktree reports whether a start asks for a worktree: the owner chose
// one, or chose auto while a live agent already works in the folder. Only
// then does the caller need the folder's git status for Place. An unknown
// choice never wants one.
func WantsWorktree(liveAgentInFolder bool, c Choice) bool {
	return c == ChoiceWorktree || (c == ChoiceAuto && liveAgentInFolder)
}

// Place is SessionStartPlacement.decide's twin (board #229). st is the
// folder's workbenchgit.ReadStatus, nil when it could not be read (or was
// not read because no worktree is wanted).
func Place(liveAgentInFolder bool, c Choice, st *workbenchgit.Status) Placement {
	if !WantsWorktree(liveAgentInFolder, c) {
		return Placement{}
	}
	if reason := unavailableReason(st); reason != "" {
		return Placement{Note: "Started in the folder: " + reason}
	}
	return Placement{Worktree: true}
}

// unavailableReason is "" when a worktree can be made; else why not.
func unavailableReason(st *workbenchgit.Status) string {
	switch {
	case st == nil:
		return "the folder's git status could not be read."
	case !st.GitAvailable:
		return "git is not available."
	case !st.Git:
		return "the folder is not in a git repository."
	case !st.StatusOK:
		return "the folder's git status could not be read."
	case st.Unborn:
		return "the repository has no commit yet."
	}
	return ""
}

// Prepared is where a placed session starts: Dir (the folder, or the new
// worktree's cwd), the worktree made (nil in the folder) and the line to
// show the owner ("" = nothing to say).
type Prepared struct {
	Dir      string
	Worktree *workbenchgit.WorktreeResult
	Notice   string
}

// HeldBranches lists every wt/… branch a session row still holds, in any
// workbench (db.DB.HeldWorktreeBranches).
type HeldBranches func(ctx context.Context) ([]string, error)

// Prepare carries a placement out, the twin of the Desktop's
// placementForNewSession and the `workbench worktree create` it runs. o.Folder
// is the workbench folder; folder is the one asked for (`--folder`; "" = the
// workbench folder). In the folder the session starts as is. For a worktree,
// the folder is resolved and refused as the CLI does
// (workbenchgit.FolderRefusal: unreadable, outside the repository), the held
// branch names are read (a name a row still holds is never handed out again;
// without them no worktree is made) and workbenchgit.CreateWorktree makes it
// (cloning the .worktreeinclude paths). It never fails: a worktree that could
// not be made starts the session in the folder with a notice saying why.
// Nothing is ever removed — a worktree made here stays even when the start
// fails later (spec 2026-10-31 §11; `workbench cleanup` lists it). The agent
// integration of the new worktree is the caller's; pass its error to
// WorktreeNotice.
func Prepare(ctx context.Context, o workbenchgit.Options, p Placement, slug, folder string, held HeldBranches) Prepared {
	if !p.Worktree {
		return Prepared{Dir: o.Folder, Notice: p.Note}
	}
	resolved, resolveErr := workbenchgit.ResolveFolder(ctx, o, folder)
	var res workbenchgit.WorktreeResult
	if res.Refused, res.RefusedDetail = workbenchgit.FolderRefusal(resolved, resolveErr); res.Refused == "" {
		taken, err := heldBranches(ctx, held)
		if err != nil {
			res.Error = err.Error()
		} else {
			wo := o
			wo.Folder = resolved.Root
			res = workbenchgit.CreateWorktree(ctx, wo, workbenchgit.WorktreeRequest{Slug: slug, Taken: taken})
		}
	}
	if !res.Created {
		reason := "the worktree could not be made."
		for _, r := range []string{res.RefusedDetail, res.Error, res.Refused} {
			if r != "" {
				reason = r
				break
			}
		}
		return Prepared{Dir: o.Folder, Notice: "Started in the folder: " + reason}
	}
	return Prepared{Dir: res.Cwd, Worktree: &res, Notice: WorktreeNotice(res, "")}
}

func heldBranches(ctx context.Context, held HeldBranches) ([]string, error) {
	if held == nil {
		return nil, errors.New("the held worktree branches could not be read")
	}
	return held(ctx)
}

// WorktreeNotice is one line for a made worktree: the missing uncommitted
// changes, then the first thing that went wrong after it existed (an include
// warning, the create warning, then integrationError).
func WorktreeNotice(res workbenchgit.WorktreeResult, integrationError string) string {
	var parts []string
	if res.BaseDirty {
		parts = append(parts, "The new worktree does not have the folder's uncommitted changes.")
	}
	for _, w := range append(append([]string{}, res.IncludeWarnings...), res.Warning, integrationError) {
		if w != "" {
			parts = append(parts, "Worktree: "+w)
			break
		}
	}
	return strings.Join(parts, " ")
}
