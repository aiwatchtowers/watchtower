package workbenchgit

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"watchtower/internal/gitbin"
)

// shortHash is how many characters of a commit id the envelopes show.
const shortHash = 7

// StatusFields is what one `git status --porcelain=v2 --branch -z` says.
type StatusFields struct {
	Branch   string `json:"branch"` // "" when detached
	Detached bool   `json:"detached"`
	Unborn   bool   `json:"unborn"` // no commit yet; Branch is still named
	Head     string `json:"head"`   // short commit id; "" when unborn
	Upstream string `json:"upstream"`
	Ahead    int    `json:"ahead"`
	Behind   int    `json:"behind"`
	// Changes counts staged, unstaged and untracked entries (ignored files
	// are not listed).
	Changes  int `json:"changes"`
	Unmerged int `json:"-"`
}

// Status is the `workbench git status` envelope.
type Status struct {
	WorkbenchID  int64  `json:"workbench_id"`
	GitAvailable bool   `json:"git_available"`
	Git          bool   `json:"git"` // the folder is a git work tree
	Note         string `json:"note"`
	StatusFields
	Dirty bool `json:"dirty"`
	// Operation is the merge, rebase, cherry-pick, revert or bisect in
	// progress in this worktree, "" for none.
	Operation   string `json:"operation"`
	TopLevel    string `json:"top_level"`
	GitDir      string `json:"git_dir"`
	CommonDir   string `json:"common_dir"`
	StatusOK    bool   `json:"status_ok"`
	StatusError string `json:"status_error"`
}

// ReadStatus reads the folder's branch and changes. It never fails: a
// folder without git says so in Git/Note, a failed status in StatusOK.
func ReadStatus(ctx context.Context, o Options) Status {
	st, _ := readStatus(ctx, o)
	return st
}

// readStatus is ReadStatus plus the repository it opened, nil when no git
// call may run in the folder.
func readStatus(ctx context.Context, o Options) (Status, *repo) {
	var st Status
	r, p, available, note, err := probe(ctx, o)
	st.GitAvailable, st.Note = available, note
	if r == nil {
		return st, nil
	}
	st.Git = true
	if err != nil {
		st.StatusError = gitError(err)
		return st, r
	}
	st.TopLevel, st.GitDir, st.CommonDir = p.topLevel, p.gitDir, p.commonDir
	if st.Operation, err = operationIn(p.gitDir); err != nil {
		st.StatusError = clip("checking for an operation in progress: " + err.Error())
		return st, r
	}
	out, err := r.git(ctx, "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal")
	if err == nil {
		st.StatusFields, err = parseStatus(out)
	}
	if err != nil {
		st.StatusError = gitError(err)
		return st, r
	}
	st.Dirty = st.Changes > 0
	st.StatusOK = true
	return st, r
}

// probe opens the folder's repository and reads its paths. A nil repo
// means no git call may run; note says why. With a repo, err is git
// failing to read the paths: the folder is in a repository all the same.
func probe(ctx context.Context, o Options) (r *repo, p paths, available bool, note string, err error) {
	r, err = open(o)
	if err != nil {
		return nil, paths{}, !errors.Is(err, gitbin.ErrUnavailable), err.Error(), nil
	}
	p, err = r.locatePaths(ctx)
	return r, p, true, "", err
}

// operations maps a marker in the git dir to the operation it means,
// checked in this order (a rebase stopped on a conflict is a rebase).
var operations = []struct{ marker, name string }{
	{"rebase-merge", "rebase"},
	{"rebase-apply", "rebase"},
	{"MERGE_HEAD", "merge"},
	{"CHERRY_PICK_HEAD", "cherry-pick"},
	{"REVERT_HEAD", "revert"},
	{"BISECT_LOG", "bisect"},
}

// operationIn is the operation whose marker is in gitDir, "" for none; a
// marker that cannot be checked is an error, not "none".
func operationIn(gitDir string) (string, error) {
	for _, op := range operations {
		_, err := os.Lstat(filepath.Join(gitDir, op.marker))
		switch {
		case err == nil:
			return op.name, nil
		case !errors.Is(err, fs.ErrNotExist):
			return "", err
		}
	}
	return "", nil
}

// parseStatus reads `git status --porcelain=v2 --branch -z` output; the
// `# branch.oid` header is required.
func parseStatus(porcelainV2Z []byte) (StatusFields, error) {
	var f StatusFields
	haveOID := false
	entries := bytes.Split(porcelainV2Z, []byte{0})
	for i := 0; i < len(entries); i++ {
		e := string(entries[i])
		switch {
		case e == "":
		case strings.HasPrefix(e, "# "):
			haveOID = haveOID || strings.HasPrefix(e, "# branch.oid ")
			if err := f.header(strings.TrimPrefix(e, "# ")); err != nil {
				return StatusFields{}, err
			}
		case strings.HasPrefix(e, "1 "), strings.HasPrefix(e, "? "):
			f.Changes++
		case strings.HasPrefix(e, "2 "):
			// A rename or copy: its original path is the next entry.
			if i+1 >= len(entries) {
				return StatusFields{}, fmt.Errorf("git status: rename entry without its original path: %q", e)
			}
			i++
			f.Changes++
		case strings.HasPrefix(e, "u "):
			f.Changes++
			f.Unmerged++
		case strings.HasPrefix(e, "! "):
		default:
			return StatusFields{}, fmt.Errorf("git status: unexpected entry %q", e)
		}
	}
	if !haveOID {
		return StatusFields{}, errors.New("git status: no branch.oid header")
	}
	return f, nil
}

func (f *StatusFields) header(h string) error {
	key, value, _ := strings.Cut(h, " ")
	switch key {
	case "branch.oid":
		if value == "(initial)" {
			f.Unborn = true
		} else {
			f.Head = value[:min(len(value), shortHash)]
		}
	case "branch.head":
		if value == "(detached)" {
			f.Detached = true
		} else {
			f.Branch = value
		}
	case "branch.upstream":
		f.Upstream = value
	case "branch.ab":
		a, b, ok := strings.Cut(value, " ")
		ahead, errA := strconv.Atoi(strings.TrimPrefix(a, "+"))
		behind, errB := strconv.Atoi(strings.TrimPrefix(b, "-"))
		if !ok || errA != nil || errB != nil {
			return fmt.Errorf("git status: bad ahead/behind %q", value)
		}
		f.Ahead, f.Behind = ahead, behind
	}
	return nil
}
