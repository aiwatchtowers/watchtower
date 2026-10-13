package sessioncleanup

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// lsregisterBinary is LaunchServices' tool at its fixed system path; it is
// never looked up on PATH.
const lsregisterBinary = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/" +
	"LaunchServices.framework/Versions/A/Support/lsregister"

// bundleDepth bounds the .app search under a worktree (spec §7 step 3).
const bundleDepth = 6

// SystemLaunchServices is the real LaunchServices: .app bundles found on
// disk, `lsregister -u` and `lsregister -dump`.
type SystemLaunchServices struct {
	run cmdRunner // nil = runCommand
}

// Bundles lists the .app bundles under root, at most bundleDepth levels
// down, skipping node_modules and .git, not following symlinks and not
// descending into a bundle. An unreadable directory is skipped.
func (SystemLaunchServices) Bundles(root string) []string {
	var bundles []string
	_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || !d.IsDir() {
			return nil //nolint:nilerr // best effort: an unreadable entry is skipped
		}
		if path == root {
			return nil
		}
		switch {
		case d.Name() == "node_modules" || d.Name() == ".git":
			return filepath.SkipDir
		case strings.HasSuffix(d.Name(), ".app"):
			bundles = append(bundles, path)
			return filepath.SkipDir
		case pathDepth(root, path) >= bundleDepth:
			return filepath.SkipDir
		}
		return nil
	})
	return bundles
}

// pathDepth is how many levels below root path is (root's child = 1).
func pathDepth(root, path string) int {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return 0
	}
	return strings.Count(rel, string(filepath.Separator)) + 1
}

// Unregister runs `lsregister -u` with the bundle's canonical path:
// LaunchServices keeps the canonical form, and -u on a deleted bundle only
// matches it (design appendix §14.4). A non-zero exit is an error.
func (s SystemLaunchServices) Unregister(ctx context.Context, bundle string) error {
	_, err := s.runner()(ctx, lsregisterBinary, "-u", canonicalPath(bundle))
	return err
}

// Stale lists the registered .app paths under `under` (as given or
// canonical) that no longer exist on disk. A path whose existence cannot be
// told is not listed.
func (s SystemLaunchServices) Stale(ctx context.Context, under string) ([]string, error) {
	out, err := s.runner()(ctx, lsregisterBinary, "-dump")
	if err != nil {
		return nil, err
	}
	paths, err := parseLsregDump(out)
	if err != nil {
		return nil, err
	}
	roots := []string{filepath.Clean(under), canonicalPath(under)}
	var stale []string
	for _, p := range paths {
		if withinAny(p, roots) && bundleGone(p) {
			stale = append(stale, p)
		}
	}
	return stale, nil
}

func (s SystemLaunchServices) runner() cmdRunner {
	if s.run != nil {
		return s.run
	}
	return runCommand
}

func withinAny(p string, roots []string) bool {
	for _, r := range roots {
		if pathWithin(p, r) {
			return true
		}
	}
	return false
}

func bundleGone(p string) bool {
	_, err := os.Lstat(p)
	return errors.Is(err, fs.ErrNotExist)
}

// parseLsregDump reads the `path:` lines of `lsregister -dump`
// ("path:   /Applications/Foo.app (0x1234)") and returns each distinct
// .app path once, in dump order.
func parseLsregDump(out []byte) ([]string, error) {
	seen := map[string]bool{}
	var paths []string
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for sc.Scan() {
		p, ok := lsregPathLine(sc.Text())
		if !ok || seen[p] {
			continue
		}
		seen[p] = true
		paths = append(paths, p)
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("reading lsregister -dump: %w", err)
	}
	return paths, nil
}

func lsregPathLine(line string) (string, bool) {
	rest, ok := strings.CutPrefix(line, "path:")
	if !ok {
		return "", false
	}
	p := strings.TrimSpace(rest)
	if i := strings.LastIndex(p, " (0x"); i >= 0 && strings.HasSuffix(p, ")") {
		p = p[:i]
	}
	if !strings.HasPrefix(p, "/") || !strings.HasSuffix(p, ".app") {
		return "", false
	}
	return p, true
}

// canonicalPath resolves symlinks on the deepest existing ancestor of p and
// re-attaches the missing tail, so a deleted bundle's path still matches the
// canonical form LaunchServices recorded (/var -> /private/var).
func canonicalPath(p string) string {
	p = filepath.Clean(p)
	var tail []string
	for cur := p; ; cur = filepath.Dir(cur) {
		if resolved, err := filepath.EvalSymlinks(cur); err == nil {
			return filepath.Join(append([]string{resolved}, tail...)...)
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return p
		}
		tail = append([]string{filepath.Base(cur)}, tail...)
	}
}
