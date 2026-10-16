package workbenchgit

import (
	"bytes"
	"context"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// branchFormat is one local branch per record, its fields and the record
// itself NUL-terminated (for-each-ref adds a newline after each record).
const branchFormat = "%(refname)%00%(objectname)%00%(committerdate:unix)%00" +
	"%(upstream:short)%00%(upstream:track,nobracket)%00%(worktreepath)%00"

const branchFields = 6

// Branch is one local branch.
type Branch struct {
	Name        string    `json:"name"`
	Current     bool      `json:"current"` // checked out in the folder's own worktree
	Head        string    `json:"head"`
	CommittedAt time.Time `json:"committed_at"` // UTC
	Upstream    string    `json:"upstream"`
	// UpstreamGone: the branch tracks an upstream that no longer exists.
	UpstreamGone bool `json:"upstream_gone"`
	Ahead        int  `json:"ahead"`
	Behind       int  `json:"behind"`
	// Worktree is set only when the branch is checked out in another
	// worktree: switching to it here is refused.
	Worktree     string `json:"worktree"`
	WorktreeName string `json:"worktree_name"`
}

// BranchList is the `workbench git branches` envelope.
type BranchList struct {
	WorkbenchID   int64    `json:"workbench_id"`
	GitAvailable  bool     `json:"git_available"`
	Git           bool     `json:"git"`
	Note          string   `json:"note"`
	Current       string   `json:"current"`
	Branches      []Branch `json:"branches"` // newest commit first
	BranchesOK    bool     `json:"branches_ok"`
	BranchesError string   `json:"branches_error"`
	// RemoteOnly are origin's branches (as of the last fetch) that no local
	// branch is named after or tracks, newest commit first. A failed
	// listing leaves it empty and says why in RemoteOnlyError; the local
	// list stands.
	RemoteOnly      []RemoteBranch `json:"remote_only"`
	RemoteOnlyError string         `json:"remote_only_error"`
	// Refused is RefusedFolderNotAWorktree or RefusedGitFailed when the
	// folder asked for could not be used; nothing was listed.
	Refused       string `json:"refused"`
	RefusedDetail string `json:"refused_detail"`
}

// RemoteBranch is one of origin's branches with no local copy.
type RemoteBranch struct {
	Name        string    `json:"name"` // without "origin/"
	Ref         string    `json:"ref"`  // "origin/<name>"
	Head        string    `json:"head"`
	CommittedAt time.Time `json:"committed_at"` // UTC
}

// remoteFormat is one remote-tracking ref per record, NUL-terminated
// fields as in branchFormat.
const remoteFormat = "%(refname)%00%(objectname)%00%(committerdate:unix)%00%(symref)%00"

const remoteFields = 4

// ListBranches lists the local branches, newest commit first, and origin's
// remote-only ones. It never fails: a folder without git says so in Git, a
// failed listing in BranchesOK (or RemoteOnlyError).
func ListBranches(ctx context.Context, o Options) BranchList {
	l := BranchList{Branches: []Branch{}, RemoteOnly: []RemoteBranch{}}
	r, p, available, note, err := probe(ctx, o)
	l.GitAvailable, l.Note = available, note
	if r == nil {
		return l
	}
	l.Git = true
	var branches []Branch
	if err == nil {
		branches, err = r.branches(ctx, p.topLevel)
	}
	if err != nil {
		l.BranchesError = gitError(err)
		return l
	}
	l.Branches, l.BranchesOK = branches, true
	for _, b := range branches {
		if b.Current {
			l.Current = b.Name
		}
	}
	if remote, err := r.remoteOnly(ctx, branches); err != nil {
		l.RemoteOnlyError = gitError(err)
	} else {
		l.RemoteOnly = remote
	}
	return l
}

// remoteOnly lists origin's remote-tracking branches that no local branch
// is named after or has as its upstream; origin/HEAD (a symref) is not a
// branch.
func (r *repo) remoteOnly(ctx context.Context, local []Branch) ([]RemoteBranch, error) {
	out, err := r.git(ctx, "for-each-ref", "--sort=-committerdate", "--format="+remoteFormat, "refs/remotes/"+Remote+"/")
	if err != nil {
		return nil, err
	}
	all, err := parseRemoteBranches(out)
	if err != nil {
		return nil, err
	}
	covered := map[string]bool{}
	for _, b := range local {
		covered[Remote+"/"+b.Name] = true
		if b.Upstream != "" {
			covered[b.Upstream] = true
		}
	}
	remote := []RemoteBranch{}
	for _, b := range all {
		if !covered[b.Ref] {
			remote = append(remote, b)
		}
	}
	return remote, nil
}

// parseRemoteBranches reads for-each-ref output in remoteFormat; symrefs
// are skipped.
func parseRemoteBranches(out []byte) ([]RemoteBranch, error) {
	fields := bytes.Split(out, []byte{0})
	if len(fields)%remoteFields != 1 {
		return nil, fmt.Errorf("git for-each-ref: %d fields is not a whole number of remote branches", len(fields)-1)
	}
	branches := []RemoteBranch{}
	for i := 0; i+remoteFields < len(fields); i += remoteFields {
		ref := strings.TrimLeft(string(fields[i]), "\n")
		name, ok := strings.CutPrefix(ref, "refs/remotes/"+Remote+"/")
		if !ok || name == "" {
			return nil, fmt.Errorf("git for-each-ref: unexpected ref %q", ref)
		}
		if len(fields[i+3]) > 0 { // origin/HEAD
			continue
		}
		sec, err := strconv.ParseInt(string(fields[i+2]), 10, 64)
		if err != nil {
			return nil, fmt.Errorf("git for-each-ref: bad commit time %q of %s", fields[i+2], ref)
		}
		head := string(fields[i+1])
		branches = append(branches, RemoteBranch{
			Name: name, Ref: Remote + "/" + name,
			Head: head[:min(len(head), shortHash)], CommittedAt: time.Unix(sec, 0).UTC(),
		})
	}
	return branches, nil
}

func (r *repo) branches(ctx context.Context, topLevel string) ([]Branch, error) {
	out, err := r.git(ctx, "for-each-ref", "--sort=-committerdate", "--format="+branchFormat, "refs/heads/")
	if err != nil {
		return nil, err
	}
	return parseBranches(out, topLevel)
}

// parseBranches reads for-each-ref output in branchFormat. topLevel is the
// folder's own worktree: the branch checked out there is Current, one
// checked out anywhere else carries Worktree.
func parseBranches(out []byte, topLevel string) ([]Branch, error) {
	fields := bytes.Split(out, []byte{0})
	// The output ends with a NUL and a newline: one field more than a whole
	// number of records.
	if len(fields)%branchFields != 1 {
		return nil, fmt.Errorf("git for-each-ref: %d fields is not a whole number of branches", len(fields)-1)
	}
	branches := []Branch{}
	for i := 0; i+branchFields < len(fields); i += branchFields {
		f := make([]string, branchFields)
		for j := range f {
			f[j] = string(fields[i+j])
		}
		b, err := parseBranch(f, topLevel)
		if err != nil {
			return nil, err
		}
		branches = append(branches, b)
	}
	return branches, nil
}

func parseBranch(f []string, topLevel string) (Branch, error) {
	// Every record after the first starts with the previous one's newline.
	ref := strings.TrimLeft(f[0], "\n")
	name, ok := strings.CutPrefix(ref, "refs/heads/")
	if !ok || name == "" {
		return Branch{}, fmt.Errorf("git for-each-ref: unexpected ref %q", ref)
	}
	sec, err := strconv.ParseInt(f[2], 10, 64)
	if err != nil {
		return Branch{}, fmt.Errorf("git for-each-ref: bad commit time %q of %s", f[2], name)
	}
	// The full id cut here, as the status cuts it: :short follows core.abbrev.
	b := Branch{Name: name, Head: f[1][:min(len(f[1]), shortHash)], CommittedAt: time.Unix(sec, 0).UTC(), Upstream: f[3]}
	b.Ahead, b.Behind, b.UpstreamGone, err = parseTrack(f[4])
	if err != nil {
		return Branch{}, fmt.Errorf("git for-each-ref: %w of %s", err, name)
	}
	if wt := f[5]; wt != "" {
		if filepath.Clean(wt) == filepath.Clean(topLevel) {
			b.Current = true
		} else {
			b.Worktree, b.WorktreeName = wt, filepath.Base(wt)
		}
	}
	return b, nil
}

// parseTrack reads %(upstream:track,nobracket): "ahead 2, behind 1",
// "ahead 2", "behind 1", "gone" or "".
func parseTrack(track string) (ahead, behind int, gone bool, err error) {
	switch track {
	case "":
		return 0, 0, false, nil
	case "gone":
		return 0, 0, true, nil
	}
	for _, part := range strings.Split(track, ", ") {
		key, value, _ := strings.Cut(part, " ")
		n, convErr := strconv.Atoi(value)
		switch {
		case convErr == nil && key == "ahead":
			ahead = n
		case convErr == nil && key == "behind":
			behind = n
		default:
			return 0, 0, false, fmt.Errorf("unexpected upstream track %q", track)
		}
	}
	return ahead, behind, false, nil
}
