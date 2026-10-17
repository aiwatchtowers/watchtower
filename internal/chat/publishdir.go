package chat

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// publishDirName is the folder under the chat work dir that holds one
// publish dir per conversation.
const publishDirName = "publish"

// ErrOutsidePublishDir is a path that does not name a place inside the
// session's publish dir; Check decides it from the text alone.
var ErrOutsidePublishDir = errors.New("outside the publish folder")

// ErrUnsafePublishPath is a path inside the publish dir that crosses
// something Write must not go through: a symlink, a hard-linked file, a
// special file, an entry of another user, or a publish dir that was replaced.
var ErrUnsafePublishPath = errors.New("unsafe path in the publish folder")

// PublishDir is a conversation's private folder for the files the Artifact
// tool publishes (the tool only takes local files). The permission gate lets
// Write — and Artifact's sources and read target — name paths inside it only;
// Check is that confinement.
type PublishDir struct {
	workDir string // the child's cwd: relative paths resolve against it
	path    string // <workDir>/publish/<conversation id>, as created
	// realPath is path with its ancestors' symlinks resolved (macOS: /var →
	// /private/var), the spelling the CLI's cwd has; "" when it equals path.
	realPath string
	dev, ino uint64 // the directory Check confines to, so a swap is refused
	lstat    func(string) (os.FileInfo, error)
}

// NewPublishDir creates <workDir>/publish/<conversationID> (0700, parents
// 0700) and checks each level is a real directory of ours that nobody else
// can write to. Every level is checked before the next is made inside it,
// so a planted symlink is refused (*WorkDirError) and never followed into a
// folder outside the work dir.
func NewPublishDir(workDir string, conversationID int64) (*PublishDir, error) {
	if !filepath.IsAbs(workDir) {
		return nil, fmt.Errorf("publish folder: work dir %q is not absolute", workDir)
	}
	if conversationID <= 0 {
		return nil, fmt.Errorf("publish folder: invalid conversation id %d", conversationID)
	}
	workDir = filepath.Clean(workDir)
	if err := os.MkdirAll(workDir, 0o700); err != nil {
		return nil, fmt.Errorf("chat work dir %s: %w", workDir, err)
	}
	if err := checkPrivateDir(workDir, os.Stderr); err != nil {
		return nil, err
	}
	parent := filepath.Join(workDir, publishDirName)
	dir := filepath.Join(parent, strconv.FormatInt(conversationID, 10))
	for _, level := range []string{parent, dir} {
		if err := os.Mkdir(level, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
			return nil, fmt.Errorf("publish folder %s: %w", level, err)
		}
		if err := checkPrivateDir(level, os.Stderr); err != nil {
			return nil, err
		}
	}
	var st syscall.Stat_t
	if err := syscall.Lstat(dir, &st); err != nil {
		return nil, fmt.Errorf("inspecting publish folder %s: %w", dir, err)
	}
	resolved, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return nil, fmt.Errorf("resolving publish folder %s: %w", dir, err)
	}
	d := &PublishDir{workDir: workDir, path: dir, dev: uint64(st.Dev), ino: st.Ino, lstat: os.Lstat}
	if resolved != dir {
		d.realPath = resolved
	}
	return d, nil
}

// Path is the publish dir as created (under the work dir).
func (d *PublishDir) Path() string { return d.path }

// Check accepts p only when it names the publish dir or a place inside it.
// The decision is lexical first, so a path outside is refused without a
// single syscall — nothing outside the dir is ever stat'ed (no TCC prompt
// for a path in ~/Documents). A relative p resolves against the work dir
// (the CLI's cwd), not the publish dir; "~" (the CLI expands it to the home
// folder) and any ".." component are refused outright, so cleaning can never
// hide a component the walk below should have seen. Then every existing
// component from the dir downward is Lstat'ed: a symlink, another user's
// entry, a special file or a hard-linked file refuses; a missing tail is
// fine (Write creates it).
func (d *PublishDir) Check(p string) error {
	if p == "" || strings.ContainsRune(p, 0) {
		return fmt.Errorf("%q: %w", p, ErrOutsidePublishDir)
	}
	if strings.HasPrefix(p, "~") {
		return fmt.Errorf("%s: %w", p, ErrOutsidePublishDir)
	}
	for _, part := range strings.Split(filepath.ToSlash(p), "/") {
		if part == ".." {
			return fmt.Errorf("%s: %w", p, ErrOutsidePublishDir)
		}
	}
	abs := p
	if !filepath.IsAbs(abs) {
		abs = filepath.Join(d.workDir, abs)
	}
	abs = filepath.Clean(abs)
	base, rel, ok := d.within(abs)
	if !ok {
		return fmt.Errorf("%s: %w", p, ErrOutsidePublishDir)
	}
	if err := d.checkDirItself(base); err != nil {
		return fmt.Errorf("%s: %w", p, err)
	}
	cur := base
	for _, part := range rel {
		cur = filepath.Join(cur, part)
		info, err := d.lstat(cur)
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("%s: %w (%w)", p, ErrUnsafePublishPath, err)
		}
		if err := checkPublishEntry(info); err != nil {
			return fmt.Errorf("%s: %w", p, err)
		}
	}
	return nil
}

// within reports whether the clean absolute path abs is the publish dir or
// inside it, under either spelling of the dir, and splits the part below it.
func (d *PublishDir) within(abs string) (base string, rel []string, ok bool) {
	for _, b := range []string{d.path, d.realPath} {
		if b == "" {
			continue
		}
		if abs == b {
			return b, nil, true
		}
		if rest, found := strings.CutPrefix(abs, b+string(filepath.Separator)); found {
			return b, strings.Split(rest, string(filepath.Separator)), true
		}
	}
	return "", nil, false
}

// checkDirItself refuses a publish dir that is no longer the directory
// NewPublishDir created (removed, or swapped for a symlink or another dir).
func (d *PublishDir) checkDirItself(base string) error {
	info, err := d.lstat(base)
	if err != nil {
		return fmt.Errorf("%w (%w)", ErrUnsafePublishPath, err)
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !info.IsDir() || !ok || uint64(st.Dev) != d.dev || st.Ino != d.ino {
		return fmt.Errorf("%w: the publish folder was replaced", ErrUnsafePublishPath)
	}
	return nil
}

// checkPublishEntry accepts a directory or a single-link regular file of
// ours; a hard-linked file would let Write change a file outside the dir.
func checkPublishEntry(info os.FileInfo) error {
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(st.Uid) != os.Getuid() {
		return fmt.Errorf("%w: %s belongs to another user", ErrUnsafePublishPath, info.Name())
	}
	switch {
	case info.Mode()&fs.ModeSymlink != 0:
		return fmt.Errorf("%w: %s is a symlink", ErrUnsafePublishPath, info.Name())
	case info.IsDir():
		return nil
	case !info.Mode().IsRegular():
		return fmt.Errorf("%w: %s is not a regular file", ErrUnsafePublishPath, info.Name())
	case st.Nlink > 1:
		return fmt.Errorf("%w: %s is hard-linked", ErrUnsafePublishPath, info.Name())
	}
	return nil
}

// Remove deletes the publish dir and everything in it (symlinks inside are
// removed, never followed). Other conversations' dirs are untouched.
func (d *PublishDir) Remove() error {
	if err := os.RemoveAll(d.path); err != nil {
		return fmt.Errorf("removing publish folder %s: %w", d.path, err)
	}
	return nil
}
