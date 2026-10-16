package reviewdiff

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// UndoRefused is an Undo the reviewer will not run; Msg is the owner-facing reason.
type UndoRefused struct{ Msg string }

func (e UndoRefused) Error() string { return e.Msg }

// Reverted is the hunk an Undo took back, Patch as applied in reverse.
type Reverted struct {
	Path, HunkID, Header, Patch string
}

const fileChangedMsg = "the file changed since this round's snapshot — refresh first"

// RevertHunk takes hunk hunkID of d back out of the work-tree file — the
// reviewer's only write there (REVIEW-01, REVIEW-02): only when the file is
// still the round tree's blob (a deleted file still absent) and `git apply
// --check -R` passed; then `git apply -R`, never with --index or --cached,
// so the owner's index and every ref stay as they were.
func (r *Repo) RevertHunk(ctx context.Context, d Diff, hunkID string) (Reverted, error) {
	f, h, ok := findHunk(d, hunkID)
	if !ok {
		if d.Truncated { // a truncated file carries no hunks, so its ids cannot be found
			return Reverted{}, UndoRefused{"undo is not available for a truncated file"}
		}
		return Reverted{}, UndoRefused{fmt.Sprintf("hunk %s is not in this round's diff", hunkID)}
	}
	if kind := undoUnsupported(f); kind != "" {
		return Reverted{}, UndoRefused{"undo is not available for a " + kind + " file"}
	}
	// The round's paths are top-relative and a workbench folder can be a
	// subdirectory: from there apply skips a path outside it and exits 0.
	out, err := r.git(ctx, nil, "rev-parse", "--show-toplevel")
	if err != nil {
		return Reverted{}, err
	}
	top := strings.TrimSpace(string(out))
	if err := checkParents(top, f.Path); err != nil {
		return Reverted{}, err
	}
	if err := r.checkUnchanged(ctx, top, f); err != nil {
		return Reverted{}, err
	}
	patch := HunkPatch(f, h)
	tmp, err := os.MkdirTemp("", "wt-review-undo-")
	if err != nil {
		return Reverted{}, err
	}
	defer func() { _ = os.RemoveAll(tmp) }()
	file := filepath.Join(tmp, "hunk.patch")
	if err := os.WriteFile(file, []byte(patch), 0o600); err != nil {
		return Reverted{}, err
	}
	// Accepted window: the agent-state read (the CLI's) and the blob check
	// precede the apply, so a write landing in between is not seen here;
	// apply --check -R and apply's own context check against the file bound
	// what such a race can do to one hunk's lines.
	// --whitespace=nowarn: a folder's apply.whitespace=fix would rewrite the lines.
	if _, err := r.run(ctx, top, nil, r.bin, "apply", "--check", "-R", "--whitespace=nowarn", file); err != nil {
		if ctxErr := ctx.Err(); ctxErr != nil {
			return Reverted{}, ctxErr
		}
		return Reverted{}, UndoRefused{"this hunk no longer applies to the file"}
	}
	if _, err := r.run(ctx, top, nil, r.bin, "apply", "-R", "--whitespace=nowarn", file); err != nil {
		return Reverted{}, err
	}
	return Reverted{Path: f.Path, HunkID: h.ID, Header: h.Header, Patch: patch}, nil
}

func findHunk(d Diff, id string) (File, Hunk, bool) {
	for _, f := range d.Files {
		for _, h := range f.Hunks {
			if h.ID == id {
				return f, h, true
			}
		}
	}
	return File{}, Hunk{}, false
}

// undoUnsupported names the kind of file Undo does not handle, "" when it does.
func undoUnsupported(f File) string {
	switch {
	case f.Status == "renamed":
		return "renamed"
	case f.Binary:
		return "binary"
	case f.NewMode == "120000" || f.OldMode == "120000":
		return "symlink"
	case f.NewMode == "160000" || f.OldMode == "160000":
		return "submodule"
	case f.CollapsedReason == "too_large":
		return "too large"
	case f.Hunks == nil:
		return "truncated"
	}
	return ""
}

// checkParents refuses a path whose parent directory under top is a
// symlink: apply -R could otherwise write or unlink outside the repository.
// A missing parent is left to checkUnchanged.
func checkParents(top, path string) error {
	dir := top
	parts := strings.Split(path, "/")
	for _, p := range parts[:len(parts)-1] {
		dir = filepath.Join(dir, p)
		info, err := os.Lstat(dir)
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		if info.Mode()&fs.ModeSymlink != 0 {
			return UndoRefused{"undo is not available for a symlink file"}
		}
	}
	return nil
}

// checkUnchanged: a deleted file is still absent; any other is still a
// regular file whose blob is the round tree's. path is top-relative.
func (r *Repo) checkUnchanged(ctx context.Context, top string, f File) error {
	info, err := os.Lstat(filepath.Join(top, filepath.FromSlash(f.Path)))
	if f.Status == "deleted" {
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		return UndoRefused{fileChangedMsg}
	}
	if errors.Is(err, fs.ErrNotExist) || err == nil && !info.Mode().IsRegular() {
		return UndoRefused{fileChangedMsg}
	}
	if err != nil {
		return err
	}
	out, err := r.run(ctx, top, nil, r.bin, "hash-object", "--", f.Path)
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(out)) != f.NewBlob {
		return UndoRefused{fileChangedMsg}
	}
	return nil
}

// HunkPatch is a one-hunk git patch of f: header lines for an added or a
// deleted file, then the hunk's header and lines verbatim.
func HunkPatch(f File, h Hunk) string {
	a, b := patchName("a/"+f.Path), patchName("b/"+f.Path)
	var s strings.Builder
	fmt.Fprintf(&s, "diff --git %s %s\n", a, b)
	tab := ""
	if strings.Contains(f.Path, " ") && a[0] != '"' {
		tab = "\t" // as git writes a name with a space, so apply reads it whole
	}
	switch f.Status {
	case "added":
		fmt.Fprintf(&s, "new file mode %s\n--- /dev/null\n+++ %s%s\n", f.NewMode, b, tab)
	case "deleted":
		fmt.Fprintf(&s, "deleted file mode %s\n--- %s%s\n+++ /dev/null\n", f.OldMode, a, tab)
	default:
		fmt.Fprintf(&s, "--- %s%s\n+++ %s%s\n", a, tab, b, tab)
	}
	s.WriteString(h.Header + "\n")
	for _, l := range h.Lines {
		s.WriteString(l + "\n")
	}
	return s.String()
}

// patchName C-quotes a name the way git does when it holds a quote, a
// backslash, a control or a non-ASCII byte.
func patchName(name string) string {
	if !strings.ContainsFunc(name, func(r rune) bool { return r == '"' || r == '\\' || r < 0x20 || r >= 0x7f }) {
		return name
	}
	var s strings.Builder
	s.WriteByte('"')
	for i := 0; i < len(name); i++ {
		switch c := name[i]; {
		case c == '"' || c == '\\':
			s.WriteByte('\\')
			s.WriteByte(c)
		case c == '\t':
			s.WriteString(`\t`)
		case c == '\n':
			s.WriteString(`\n`)
		case c < 0x20 || c >= 0x7f:
			fmt.Fprintf(&s, `\%03o`, c)
		default:
			s.WriteByte(c)
		}
	}
	s.WriteByte('"')
	return s.String()
}
