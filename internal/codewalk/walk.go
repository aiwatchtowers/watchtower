// Package codewalk lists a workbench folder's files: the one walk that the
// symbol index (`watchtower code index`) and the text search (`watchtower
// code search`) share, so both agree on what "the workbench's files" are.
//
// Inside a git repository the list is git's (`ls-files --cached --others
// --exclude-standard`, git found through internal/gitbin, never the macOS
// /usr/bin/git shim); elsewhere, when git is missing or fails, or when it
// lists nothing (a folder the repository ignores), it is a directory walk
// that skips the Desktop's CodeFileTree.hiddenNames. Either
// way it never lists a symlink that leaves the folder, a file larger than
// MaxSearchBytes, or a file whose first 8 KB hold a NUL byte.
package codewalk

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"iter"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"

	"watchtower/internal/gitbin"
)

const (
	// MaxIndexBytes is the largest file the symbol index parses.
	MaxIndexBytes = 2 << 20
	// MaxSearchBytes is the largest file the walk lists and the search
	// reads (the editor's own cap); the index skips files above
	// MaxIndexBytes itself.
	MaxSearchBytes = 5 << 20
	// headBytes is how much of a file is checked for a NUL byte.
	headBytes = 8 << 10
)

// hiddenNames is a copy of the Desktop's CodeFileTree.hiddenNames, pinned
// to it by testdata/hidden_names.json (read by both test suites). The
// directory walk never lists an entry with one of these names nor descends
// into one.
var hiddenNames = map[string]bool{
	".git": true, ".build": true, "node_modules": true, ".DS_Store": true,
	".swiftpm": true, "DerivedData": true, ".idea": true, ".worktrees": true,
}

// File is one listed file.
type File struct {
	// Rel is the path relative to the walked folder, slash-separated.
	Rel  string
	Size int64
}

// ErrSkipped is Lookup's answer for a path that exists but is not one the
// walk lists: a directory, a symlink leaving the folder, a binary file, a
// file larger than MaxSearchBytes, or a path outside the folder.
var ErrSkipped = errors.New("not a listed file")

// Files yields the folder's files. A yielded error ends the sequence: the
// folder cannot be read, or ctx was cancelled. Entries the walk cannot read
// (a vanished file, an unreadable subdirectory) are skipped like binaries.
// Order is git's or the walk's; callers must not depend on it.
func Files(ctx context.Context, root string) iter.Seq2[File, error] {
	return files(ctx, root, gitbin.Locate)
}

func files(ctx context.Context, root string, locateGit func() (string, bool)) iter.Seq2[File, error] {
	return func(yield func(File, error) bool) {
		w, err := newWalker(root)
		if err != nil {
			yield(File{}, err)
			return
		}
		names := gitNames(ctx, locateGit, root)
		if err := ctx.Err(); err != nil {
			yield(File{}, err)
			return
		}
		if names != nil {
			w.list(ctx, slices.Values(names), yield)
			return
		}
		w.list(ctx, w.walkNames(ctx), yield)
	}
}

// warnings receives the walk's one-line notes (a git fallback); the
// command's stderr.
var warnings io.Writer = os.Stderr

// gitNames is git's list of the folder's files, or nil for the directory
// walk: outside a repository, without a git, or — noted on warnings —
// when git fails (a broken worktree link, a repository it refuses to
// read) or lists nothing (a folder the repository ignores). Never zero
// files because of git.
func gitNames(ctx context.Context, locateGit func() (string, bool), root string) []string {
	bin, ok := locateGit()
	if !ok || !gitbin.InsideRepository(root) {
		return nil
	}
	names, err := gitListFiles(ctx, bin, root)
	switch {
	case ctx.Err() != nil:
		return nil
	case err != nil:
		fmt.Fprintf(warnings, "code walk: %v; walking the folder instead\n", err)
		return nil
	case len(names) == 0:
		fmt.Fprintf(warnings, "code walk: git lists no files in %s (ignored by its repository?); walking the folder instead\n", root)
		return nil
	}
	return names
}

// walker turns candidate names into listed files: it checks each one and
// lists every real file at most once.
type walker struct {
	root, realRoot string
	// seen holds the real path of every file already listed.
	seen map[string]bool
}

func newWalker(root string) (*walker, error) {
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return nil, fmt.Errorf("reading folder: %w", err)
	}
	info, err := os.Stat(realRoot)
	if err != nil {
		return nil, fmt.Errorf("reading folder: %w", err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("reading folder %s: not a directory", root)
	}
	return &walker{root: root, realRoot: realRoot, seen: map[string]bool{}}, nil
}

// list yields the files among names. Paths through a symlink wait until
// every direct path is listed, so a link to a listed file is dropped and
// the file appears once, under its own name.
func (w *walker) list(ctx context.Context, names iter.Seq[string], yield func(File, error) bool) {
	var links []string
	for rel := range names {
		if err := ctx.Err(); err != nil {
			yield(File{}, err)
			return
		}
		f, realPath, isLink, err := w.check(rel)
		if err != nil {
			continue
		}
		if isLink {
			links = append(links, rel)
			continue
		}
		if !w.emit(f, realPath, yield) {
			return
		}
	}
	for _, rel := range links {
		if err := ctx.Err(); err != nil {
			yield(File{}, err)
			return
		}
		f, realPath, _, err := w.check(rel)
		if err != nil {
			continue
		}
		if !w.emit(f, realPath, yield) {
			return
		}
	}
}

// emit yields f unless its real file was listed already; it reports
// whether the walk goes on.
func (w *walker) emit(f File, realPath string, yield func(File, error) bool) bool {
	if w.seen[realPath] {
		return true
	}
	w.seen[realPath] = true
	return yield(f, nil)
}

// check decides whether rel (relative to the folder) is a listed file. It
// returns the file, its real path and whether rel goes through a symlink
// (in any component), or
// fs.ErrNotExist / ErrSkipped / a read error.
func (w *walker) check(rel string) (f File, realPath string, isLink bool, err error) {
	clean := filepath.Clean(filepath.FromSlash(rel))
	if filepath.IsAbs(clean) || clean == "." || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return File{}, "", false, ErrSkipped
	}
	abs := filepath.Join(w.realRoot, clean)
	if _, err := os.Lstat(abs); err != nil {
		return File{}, "", false, err
	}
	// Every component is resolved, not just the last: a file reached
	// through a directory link is judged (inside, seen) by its real path.
	if realPath, err = filepath.EvalSymlinks(abs); err != nil {
		return File{}, "", true, ErrSkipped // dangling or looping link
	}
	isLink = realPath != abs
	if !inside(w.realRoot, realPath) {
		return File{}, "", isLink, ErrSkipped
	}
	info, err := os.Stat(realPath)
	if err != nil {
		return File{}, "", isLink, err
	}
	if !info.Mode().IsRegular() || info.Size() > MaxSearchBytes {
		return File{}, "", isLink, ErrSkipped
	}
	binary, err := hasNUL(realPath)
	if err != nil {
		return File{}, "", isLink, err
	}
	if binary {
		return File{}, "", isLink, ErrSkipped
	}
	return File{Rel: filepath.ToSlash(clean), Size: info.Size()}, realPath, isLink, nil
}

// Lookup checks one path relative to root the way the walk checks every
// candidate: fs.ErrNotExist when nothing is there, ErrSkipped when the walk
// would not list it. It does not ask git; Ignored does, for a batch.
func Lookup(root, rel string) (File, error) {
	w, err := newWalker(root)
	if err != nil {
		return File{}, err
	}
	f, _, _, err := w.check(rel)
	return f, err
}

// Ignored reports which of rels (paths relative to root, as a caller
// names them) the folder's repository ignores, so a caller naming paths
// leaves out what Files would not list. One `git check-ignore --stdin`
// answers the batch; like ls-files it never counts a tracked file as
// ignored. It is nil outside a repository, without a git, when the
// folder itself is ignored (Files then walks it, .gitignore aside) and —
// noted on warnings — when git fails. A path the walk would skip anyway
// (absolute, outside the folder) is not asked about.
func Ignored(ctx context.Context, root string, rels []string) map[string]bool {
	return ignored(ctx, root, rels, gitbin.Locate)
}

func ignored(ctx context.Context, root string, rels []string, locateGit func() (string, bool)) map[string]bool {
	bin, ok := locateGit()
	if !ok || len(rels) == 0 || !gitbin.InsideRepository(root) {
		return nil
	}
	in, asked := checkIgnoreInput(rels)
	out, err := gitCheckIgnore(ctx, bin, root, in)
	if err != nil {
		if ctx.Err() == nil {
			fmt.Fprintf(warnings, "code walk: %v; .gitignore not applied to the named paths\n", err)
		}
		return nil
	}
	set := map[string]bool{}
	for name := range bytes.SplitSeq(out, []byte{0}) {
		if string(name) == "." {
			return nil
		}
		for _, rel := range asked[string(name)] {
			set[rel] = true
		}
	}
	return set
}

// checkIgnoreInput is check-ignore's stdin for rels — the folder itself,
// then each path inside the folder once, clean, NUL-separated — and the
// caller's spellings of each clean path.
func checkIgnoreInput(rels []string) (in []byte, asked map[string][]string) {
	asked = map[string][]string{}
	in = []byte(".\x00")
	for _, rel := range rels {
		clean := filepath.ToSlash(filepath.Clean(filepath.FromSlash(rel)))
		if filepath.IsAbs(clean) || clean == "." || clean == ".." || strings.HasPrefix(clean, "../") {
			continue
		}
		if asked[clean] == nil {
			in = append(append(in, clean...), 0)
		}
		asked[clean] = append(asked[clean], rel)
	}
	return in, asked
}

// gitCheckIgnore runs check-ignore from the folder over the NUL-separated
// paths of stdin and returns the ignored ones, NUL-separated. Its exit 1
// (none ignored) is not a failure.
func gitCheckIgnore(ctx context.Context, bin, root string, stdin []byte) ([]byte, error) {
	c := exec.CommandContext(ctx, bin, "check-ignore", "--stdin", "-z")
	c.Dir = root
	c.Env = gitEnv()
	c.Stdin = bytes.NewReader(stdin)
	out, err := c.Output()
	var exit *exec.ExitError
	if errors.As(err, &exit) && exit.ExitCode() == 1 {
		return nil, nil
	}
	if err != nil {
		return nil, gitError("git check-ignore", err)
	}
	return out, nil
}

func inside(root, path string) bool {
	rel, err := filepath.Rel(root, path)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// hasNUL reports whether the file's first headBytes hold a NUL byte.
func hasNUL(path string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer f.Close()
	buf := make([]byte, headBytes)
	n, err := io.ReadFull(f, buf)
	if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) && !errors.Is(err, io.EOF) {
		return false, err
	}
	return bytes.IndexByte(buf[:n], 0) >= 0, nil
}

// walkNames yields every non-directory entry below the folder, skipping
// the hidden names and anything it cannot read.
func (w *walker) walkNames(ctx context.Context) iter.Seq[string] {
	return func(yield func(string) bool) {
		_ = filepath.WalkDir(w.realRoot, func(path string, d fs.DirEntry, err error) error {
			if ctx.Err() != nil {
				return filepath.SkipAll // list reports the cancellation
			}
			if err != nil {
				// An unreadable entry is skipped, like a binary; the root
				// itself was read by newWalker.
				return skipUnreadable(d)
			}
			if path == w.realRoot {
				return nil
			}
			if hiddenNames[d.Name()] {
				if d.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
			if d.IsDir() {
				return nil
			}
			// WalkDir joins every path onto the root it was given.
			rel := strings.TrimPrefix(path[len(w.realRoot):], string(filepath.Separator))
			if !yield(filepath.ToSlash(rel)) {
				return filepath.SkipAll
			}
			return nil
		})
	}
}

// skipUnreadable is the WalkDir answer for an entry it could not read:
// skip it (a directory with all it holds) and go on.
func skipUnreadable(d fs.DirEntry) error {
	if d != nil && d.IsDir() {
		return filepath.SkipDir
	}
	return nil
}

// repositoryEnv are the variables that would point git at a repository
// other than the folder's; an inherited one is dropped (as in
// internal/workbenchgit).
var repositoryEnv = []string{
	"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
	"GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_PREFIX",
}

// gitEnv is the environment git runs with: no inherited repository
// variables, no optional locks, no prompts, C locale.
func gitEnv() []string {
	env := slices.DeleteFunc(os.Environ(), func(kv string) bool {
		key, _, _ := strings.Cut(kv, "=")
		return slices.Contains(repositoryEnv, key)
	})
	return append(env, "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0", "LC_ALL=C")
}

// gitListFiles runs ls-files from the folder, so the paths come back
// relative to it and limited to it.
func gitListFiles(ctx context.Context, bin, root string) ([]string, error) {
	c := exec.CommandContext(ctx, bin, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
	c.Dir = root
	c.Env = gitEnv()
	out, err := c.Output()
	if err != nil {
		return nil, gitError("git ls-files", err)
	}
	names := []string{}
	for name := range bytes.SplitSeq(out, []byte{0}) {
		if len(name) > 0 {
			names = append(names, string(name))
		}
	}
	return names, nil
}

// gitError wraps a failed git command's error with the first line of its
// stderr, if it wrote one.
func gitError(what string, err error) error {
	var exit *exec.ExitError
	if errors.As(err, &exit) && len(exit.Stderr) > 0 {
		msg, _, _ := strings.Cut(strings.TrimSpace(string(exit.Stderr)), "\n")
		return fmt.Errorf("%s: %w: %s", what, err, msg)
	}
	return fmt.Errorf("%s: %w", what, err)
}
