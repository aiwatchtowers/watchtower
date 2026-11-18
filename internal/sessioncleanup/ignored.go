package sessioncleanup

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"
)

// topLevelBuild is a build output folder that counts as a cache only at the
// worktree's root or the workbench folder's root (`build/`, the repository's
// own output); deeper, `build` is any folder name (#1878).
const topLevelBuild = "build"

// ignoredJudge tells, for one worktree, the git-ignored paths a removal
// would lose (W10, #1878) from the ones it loses nothing of: the caches W9
// skips too (regenerableCaches) at any depth, `build` at a root, a
// .DS_Store, Watchtower's integration files whose bytes are what the
// install writes there now, and a file .worktreeinclude copied in that is
// still byte-identical to its source in the main worktree. Nothing is
// judged by its name alone that can hold the owner's words.
type ignoredJudge struct {
	ctx      context.Context
	root     string
	mainRoot string   // the main worktree, the .worktreeinclude source; "" = unknown
	bases    []string // where the integration lives: "" (the root) and the workbench folder's subfolder
	render   func(folder string) (map[string][]byte, error)
	rendered map[string]map[string][]byte // base -> rendered files
	deadline time.Time
	budget   time.Duration
	seen     int
}

// ignoredWork is the first git-ignored path in the worktree at root that a
// removal would lose, "" when there is none. git lists an ignored folder as
// one entry ("dir/"); such a folder is walked without following symlinks.
// The walk shares W9's budget and clock; over it, or on any git or read
// failure, the result is an error, so the catch keeps the worktree
// (check_failed).
func (b *builder) ignoredWork(ctx context.Context, root string, budget time.Duration) (string, error) {
	out, err := b.repo.git.output(ctx, root, "status", "--porcelain", "-z", "--ignored=matching",
		"--untracked-files=all", "--ignore-submodules=all")
	if err != nil {
		return "", fmt.Errorf("listing the ignored files of %s: %w", root, err)
	}
	j := b.newIgnoredJudge(ctx, root, budget)
	for _, rec := range bytes.Split(out, []byte{0}) {
		entry, ok := bytes.CutPrefix(rec, []byte("!! "))
		if !ok || len(entry) == 0 {
			continue
		}
		found, err := j.entry(string(entry))
		if err != nil || found != "" {
			return found, err
		}
	}
	return "", nil
}

func (b *builder) newIgnoredJudge(ctx context.Context, root string, budget time.Duration) *ignoredJudge {
	j := &ignoredJudge{ctx: ctx, root: root, bases: []string{""}, rendered: map[string]map[string][]byte{},
		deadline: time.Now().Add(budget), budget: budget}
	for _, w := range b.repo.worktrees {
		if w.Main {
			j.mainRoot = w.Root
		}
	}
	if j.mainRoot != "" {
		if rel, err := filepath.Rel(j.mainRoot, b.repo.folder); err == nil && rel != "." && !strings.HasPrefix(rel, "..") {
			j.bases = append(j.bases, filepath.ToSlash(rel))
		}
	}
	if render := b.deps.Integration; render != nil {
		id := b.req.WorkbenchID
		j.render = func(folder string) (map[string][]byte, error) { return render(ctx, id, folder) }
	}
	return j
}

// entry judges one line of git's listing.
func (j *ignoredJudge) entry(rel string) (string, error) {
	if !strings.HasSuffix(rel, "/") {
		return j.file(rel)
	}
	rel = strings.TrimSuffix(rel, "/")
	if j.cacheDir(rel) {
		return "", nil
	}
	var found string
	var fileErr error
	err := filepath.WalkDir(filepath.Join(j.root, filepath.FromSlash(rel)), func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := j.tick(); err != nil {
			return err
		}
		r, err := filepath.Rel(j.root, p)
		if err != nil {
			return err
		}
		r = filepath.ToSlash(r)
		if d.IsDir() {
			if j.cacheDir(r) {
				return fs.SkipDir
			}
			return nil
		}
		if found, fileErr = j.file(r); fileErr != nil || found != "" {
			return errStopWalk
		}
		return nil
	})
	switch {
	case errors.Is(err, errStopWalk):
		return found, fileErr
	case err != nil:
		return "", fmt.Errorf("reading the ignored folder %s: %w", rel, err)
	}
	return "", nil
}

// errStopWalk ends a walk at the first unsaved file (or a failed judgement,
// which file already returned).
var errStopWalk = errors.New("stop")

// tick counts a visited entry and checks the clock every nestedClockEvery
// entries, as W9 does.
func (j *ignoredJudge) tick() error {
	j.seen++
	if j.seen%nestedClockEvery == 0 {
		return nestedWalkLimit(j.ctx, j.deadline, j.budget)
	}
	return nil
}

// cacheDir: a cache folder at any depth, or `build` at a root.
func (j *ignoredJudge) cacheDir(rel string) bool {
	for _, part := range strings.Split(rel, "/") {
		if regenerableCaches[part] {
			return true
		}
	}
	for _, base := range j.bases {
		if r, ok := under(base, rel); ok && (r == topLevelBuild || strings.HasPrefix(r, topLevelBuild+"/")) {
			return true
		}
	}
	return false
}

// file returns rel when the ignored file (or symlink, or special file) at
// rel is unsaved work, "" when a removal loses nothing of it.
func (j *ignoredJudge) file(rel string) (string, error) {
	if j.cacheDir(rel) || path.Base(rel) == ".DS_Store" {
		return "", nil
	}
	p := filepath.Join(j.root, filepath.FromSlash(rel))
	info, err := os.Lstat(p)
	if err != nil {
		return "", fmt.Errorf("reading the ignored file %s: %w", rel, err)
	}
	if !info.Mode().IsRegular() {
		return rel, nil
	}
	ok, err := j.integration(rel, p)
	if err != nil || ok {
		return "", err
	}
	if ok, err = j.includedCopy(rel, p, info); err != nil || ok {
		return "", err
	}
	return rel, nil
}

// integration: rel is a file Watchtower's install writes at a base, and its
// bytes are what the install writes there now.
func (j *ignoredJudge) integration(rel, p string) (bool, error) {
	if j.render == nil {
		return false, nil
	}
	for _, base := range j.bases {
		r, ok := under(base, rel)
		if !ok || !(strings.HasPrefix(r, ".claude/") || strings.HasPrefix(r, ".agents/")) {
			continue
		}
		files, err := j.renderAt(base)
		if err != nil {
			return false, err
		}
		want, ok := files[r]
		if !ok {
			continue
		}
		got, err := os.ReadFile(p)
		if err != nil {
			return false, fmt.Errorf("reading %s: %w", rel, err)
		}
		if bytes.Equal(got, want) {
			return true, nil
		}
	}
	return false, nil
}

func (j *ignoredJudge) renderAt(base string) (map[string][]byte, error) {
	if files, ok := j.rendered[base]; ok {
		return files, nil
	}
	files, err := j.render(filepath.Join(j.root, filepath.FromSlash(base)))
	if err != nil {
		return nil, fmt.Errorf("rendering Watchtower's integration files: %w", err)
	}
	j.rendered[base] = files
	return files, nil
}

// includedCopy: the main worktree holds a regular file at the same path
// with the same bytes — a .worktreeinclude copy nobody changed.
func (j *ignoredJudge) includedCopy(rel, p string, info fs.FileInfo) (bool, error) {
	if j.mainRoot == "" || j.mainRoot == j.root {
		return false, nil
	}
	src := filepath.Join(j.mainRoot, filepath.FromSlash(rel))
	sinfo, err := os.Lstat(src)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("reading %s in the main worktree: %w", rel, err)
	}
	if !sinfo.Mode().IsRegular() || sinfo.Size() != info.Size() {
		return false, nil
	}
	return sameBytes(p, src)
}

func sameBytes(a, b string) (bool, error) {
	fa, err := os.Open(a)
	if err != nil {
		return false, err
	}
	defer func() { _ = fa.Close() }()
	fb, err := os.Open(b)
	if err != nil {
		return false, err
	}
	defer func() { _ = fb.Close() }()
	ba, bb := make([]byte, 64<<10), make([]byte, 64<<10)
	for {
		na, ea := io.ReadFull(fa, ba)
		nb, eb := io.ReadFull(fb, bb)
		if na != nb || !bytes.Equal(ba[:na], bb[:nb]) {
			return false, nil
		}
		doneA := errors.Is(ea, io.EOF) || errors.Is(ea, io.ErrUnexpectedEOF)
		doneB := errors.Is(eb, io.EOF) || errors.Is(eb, io.ErrUnexpectedEOF)
		switch {
		case doneA && doneB:
			return true, nil
		case doneA != doneB:
			return false, nil
		case ea != nil:
			return false, ea
		case eb != nil:
			return false, eb
		}
	}
}

// under is rel relative to base ("" = the root), and whether it is inside.
func under(base, rel string) (string, bool) {
	if base == "" {
		return rel, true
	}
	if r, ok := strings.CutPrefix(rel, base+"/"); ok {
		return r, true
	}
	return "", false
}
