package workbenchgit

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const includeFile = ".worktreeinclude"

// IncludeFile names the list, at the repository's top level, of ignored
// paths every new session worktree gets a copy of.
const IncludeFile = includeFile

// IncludeSource is the checkout a session worktree made for the workbench
// folder in o gets its .worktreeinclude copies from: the top level of the
// checkout holding o.Folder (it may be a linked one), located by the same
// probe CreateWorktree and EnsureWorktree read it with (readStatus).
func IncludeSource(ctx context.Context, o Options) (string, error) {
	r, p, _, note, err := probe(ctx, o)
	switch {
	case r == nil:
		return "", errors.New(note)
	case err != nil:
		return "", err
	case p.topLevel == "":
		return "", errors.New("no top level for " + o.Folder)
	}
	return p.topLevel, nil
}

// IncludeListArgs is the `git ls-files` the include runs in the main work
// tree under rule ("--exclude-from=<list>" for what the list matches,
// "--exclude-standard" for what git ignores): untracked ignored paths,
// directories collapsed ("node_modules/"), NUL-separated.
func IncludeListArgs(rule string) []string {
	return []string{"ls-files", "-z", "--others", "--ignored", "--directory", rule}
}

// IncludedPaths is what the include copies, given the two listings: the
// matched paths git ignores (intersectCovered). The session cleanup's W10
// reads it to tell an unchanged copy from the agent's work (#1878).
func IncludedPaths(matched, ignored []string) []string { return intersectCovered(matched, ignored) }

// IncludeCovers reports whether rel (slash-separated, from the top level)
// is one of paths or inside one of its directories.
func IncludeCovers(paths []string, rel string) bool {
	for _, p := range paths {
		if rel == p || (strings.HasSuffix(p, "/") && strings.HasPrefix(rel, p)) {
			return true
		}
	}
	return false
}

var errCloneUnsupported = errors.New("the volume does not support clones")

// cloneFile and copyFallbackLimit are package vars so tests can force the
// fallback and shrink its budget.
var (
	cloneFile               = clonefileNative
	copyFallbackLimit int64 = 1 << 30
)

// includeInto copies into dest every path of the main work tree that
// .worktreeinclude matches and git ignores (spec §6). It never fails the
// create: what could not be copied is a warning.
func includeInto(ctx context.Context, r *repo, p paths, dest string) (included, warnings []string) {
	included, warnings = []string{}, []string{}
	list := filepath.Join(p.topLevel, includeFile)
	if _, err := os.Stat(list); err != nil {
		return included, warnings
	}
	tr := &repo{o: Options{Folder: p.topLevel, Run: r.o.Run, Locate: r.o.Locate}, bin: r.bin}
	matched, err := tr.lsIgnored(ctx, "--exclude-from="+list)
	if err != nil {
		return included, []string{clip("reading " + includeFile + ": " + gitError(err))}
	}
	ignored, err := tr.lsIgnored(ctx, "--exclude-standard")
	if err != nil {
		return included, []string{clip("reading the ignored files: " + gitError(err))}
	}
	var budget int64
	for _, rel := range intersectCovered(matched, ignored) {
		clean := filepath.FromSlash(strings.TrimSuffix(rel, "/"))
		src, dst := filepath.Join(p.topLevel, clean), filepath.Join(dest, clean)
		if _, err := os.Lstat(dst); err == nil {
			continue
		}
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			warnings = append(warnings, clip("not copied: "+rel+": "+err.Error()))
			continue
		}
		err := cloneFile(src, dst)
		if errors.Is(err, errCloneUnsupported) {
			size, sizeErr := treeSize(src)
			if sizeErr != nil || budget+size > copyFallbackLimit {
				warnings = append(warnings, fmt.Sprintf("not copied: %s (%s, the volume does not support clones)", rel, humanSize(size)))
				continue
			}
			budget += size
			err = copyTree(src, dst)
		}
		if err != nil {
			_ = os.RemoveAll(dst) // dst did not exist before this call
			warnings = append(warnings, clip("not copied: "+rel+": "+err.Error()))
			continue
		}
		included = append(included, rel)
	}
	return included, warnings
}

// lsIgnored lists untracked ignored paths under the given exclude rule,
// directories collapsed ("node_modules/").
func (r *repo) lsIgnored(ctx context.Context, rule string) ([]string, error) {
	out, err := r.git(ctx, IncludeListArgs(rule)...)
	if err != nil {
		return nil, err
	}
	var found []string
	for b := range bytes.SplitSeq(out, []byte{0}) {
		if len(b) > 0 {
			found = append(found, string(b))
		}
	}
	return found, nil
}

// intersectCovered keeps the matched paths that are ignored: equal to an
// ignored entry or inside an ignored directory. Sorted, deduplicated, and a
// path inside another kept path dropped (the parent's copy covers it).
func intersectCovered(matched, ignored []string) []string {
	covered := func(path string) bool {
		for _, ig := range ignored {
			if path == ig || (strings.HasSuffix(ig, "/") && strings.HasPrefix(path, ig)) {
				return true
			}
		}
		return false
	}
	var keep []string
	for _, m := range matched {
		if covered(m) {
			keep = append(keep, m)
		}
	}
	sort.Strings(keep)
	var out []string
	for _, k := range keep {
		if n := len(out); n > 0 && (out[n-1] == k || (strings.HasSuffix(out[n-1], "/") && strings.HasPrefix(k, out[n-1]))) {
			continue
		}
		out = append(out, k)
	}
	return out
}

func treeSize(root string) (int64, error) {
	var total int64
	err := filepath.WalkDir(root, func(_ string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.Type().IsRegular() {
			info, err := d.Info()
			if err != nil {
				return err
			}
			total += info.Size()
		}
		return nil
	})
	return total, err
}

// copyTree copies a file, symlink (as a link) or directory tree, keeping
// permission bits; nothing is followed. Every filesystem operation below the
// two top-level paths goes through os.Root handles, so a path swapped for a
// symlink mid-walk cannot escape either tree.
func copyTree(src, dst string) (err error) {
	srcRoot, err := os.OpenRoot(filepath.Dir(src))
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, srcRoot.Close()) }()
	dstRoot, err := os.OpenRoot(filepath.Dir(dst))
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, dstRoot.Close()) }()
	srcBase, dstBase := filepath.Base(src), filepath.Base(dst)
	info, err := srcRoot.Lstat(srcBase)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return copyEntry(srcRoot, dstRoot, srcBase, dstBase, info)
	}
	if err := copyEntry(srcRoot, dstRoot, srcBase, dstBase, info); err != nil {
		return err
	}
	return fs.WalkDir(srcRoot.FS(), srcBase, func(rel string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if rel == srcBase {
			return nil
		}
		info, err := srcRoot.Lstat(rel)
		if err != nil {
			return err
		}
		sub := strings.TrimPrefix(rel, srcBase+"/")
		return copyEntry(srcRoot, dstRoot, rel, dstBase+"/"+sub, info)
	})
}

// copyEntry copies one entry (not its children) between two roots.
func copyEntry(srcRoot, dstRoot *os.Root, from, to string, info fs.FileInfo) error {
	switch {
	case info.Mode()&fs.ModeSymlink != 0:
		target, err := srcRoot.Readlink(from)
		if err != nil {
			return err
		}
		return dstRoot.Symlink(target, to)
	case info.IsDir():
		return dstRoot.Mkdir(to, info.Mode().Perm())
	case info.Mode().IsRegular():
		return copyRegular(srcRoot, dstRoot, from, to, info.Mode().Perm())
	}
	return nil // sockets, devices: skipped
}

func copyRegular(srcRoot, dstRoot *os.Root, from, to string, perm fs.FileMode) error {
	in, err := srcRoot.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := dstRoot.OpenFile(to, os.O_CREATE|os.O_EXCL|os.O_WRONLY, perm)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func humanSize(n int64) string {
	switch {
	case n >= 1<<30:
		return fmt.Sprintf("%.1f GB", float64(n)/(1<<30))
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
	}
	return fmt.Sprintf("%d bytes", n)
}
