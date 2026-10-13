package sessioncleanup

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"path/filepath"
	"time"
)

// nestedClockEvery is how many entries the nested walk visits between two
// looks at the clock and the context.
const nestedClockEvery = 1024

// regenerableCaches names the dependency and build caches W9's walk skips
// at any depth: a `.git` inside them is a package manager's checkout
// (`.build/checkouts/<pkg>/.git`, `node_modules/**/.git`), rebuilt on
// demand, not someone's work. A listed worktree placed inside one is still
// found by catchNested's listing check, which does not walk.
var regenerableCaches = map[string]bool{
	".build":       true,
	"node_modules": true,
	"DerivedData":  true,
	"Pods":         true,
	".swiftpm":     true,
}

// errNestedFound ends the walk at the first nested repository.
var errNestedFound = errors.New("nested repository found")

// findNestedRepository walks root, not following symlinks, for a `.git`
// file or directory other than root's own, outside the regenerable caches,
// and returns its parent ("" for none). An unreadable entry, a cancelled context or a walk over budget is
// an error: the caller keeps the worktree (fail closed).
func findNestedRepository(ctx context.Context, root string, budget time.Duration) (string, error) {
	deadline := time.Now().Add(budget)
	own := filepath.Join(root, ".git")
	found, seen := "", 0
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.Name() == ".git" && path != own {
			found = filepath.Dir(path)
			return errNestedFound
		}
		if d.IsDir() && path != root && (path == own || regenerableCaches[d.Name()]) {
			return filepath.SkipDir
		}
		seen++
		if seen%nestedClockEvery == 0 {
			return nestedWalkLimit(ctx, deadline, budget)
		}
		return nil
	})
	if errors.Is(err, errNestedFound) {
		return found, nil
	}
	if err != nil {
		return "", fmt.Errorf("looking for a repository nested in %s: %w", root, err)
	}
	return "", nil
}

func nestedWalkLimit(ctx context.Context, deadline time.Time, budget time.Duration) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if time.Now().After(deadline) {
		return fmt.Errorf("over the %s budget", budget)
	}
	return nil
}
