package workbenchgit

import (
	"context"
	"slices"
	"strings"
)

// ListFiles lists every file of the folder git does not ignore — tracked
// ones and untracked ones no ignore rule matches — as slash-separated paths
// relative to the folder, sorted. It only reads. The error is
// gitbin.ErrUnavailable, a folder outside a repository, or the git failure.
func ListFiles(ctx context.Context, o Options) ([]string, error) {
	r, err := open(o)
	if err != nil {
		return nil, err
	}
	out, err := r.git(ctx, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", ".")
	if err != nil {
		return nil, err
	}
	var paths []string
	for p := range strings.SplitSeq(string(out), "\x00") {
		if p != "" {
			paths = append(paths, p)
		}
	}
	// A conflicted path is listed once per stage.
	slices.Sort(paths)
	return slices.Compact(paths), nil
}
