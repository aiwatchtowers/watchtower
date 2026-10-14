package workbenchgit

import "context"

// includeInto copies the .worktreeinclude paths into the new worktree
// (spec §6); filled in by the include task.
func includeInto(ctx context.Context, r *repo, p paths, dest string) (included, warnings []string) {
	return []string{}, []string{}
}
