package memory

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/go-git/go-git/v5/plumbing/storer"
)

// ErrVaultNotInitialized is returned by OpenExistingVault when no vault
// repository exists at the path. Read-only surfaces (memory open/reindex,
// seed --dry-run) use it to report "memory vault not initialized" instead of
// creating a vault as a side effect of a read.
var ErrVaultNotInitialized = errors.New("memory vault not initialized")

// ErrLocked is returned by Vault.Lock when another process — the daemon's
// memory phase or a CLI memory command — currently holds the memory lock.
var ErrLocked = errors.New("another memory run is in progress")

// Vault is the on-disk memory store: a git repository of markdown nodes. It
// is the source of truth; the SQLite index is derived from it. All machine
// writes go through WriteNodes so that every logical operation is exactly one
// commit with a structured message.
type Vault struct {
	path string
	repo *git.Repository
}

// CommitMsg is the structured commit message for machine writes. It renders
// as:
//
//	memory(<op>): <summary>
//
//	Nodes: <id> <id> ...
//	Cause: <cause>
//
// The Nodes line is omitted when NodeIDs is empty (init, owner-edit).
type CommitMsg struct {
	Op      string
	Summary string
	Cause   string // run:<pipeline_run_id> | owner-edit | seed | init
	NodeIDs []string
}

func (m CommitMsg) render() string {
	var b strings.Builder
	fmt.Fprintf(&b, "memory(%s): %s\n\n", m.Op, m.Summary)
	if len(m.NodeIDs) > 0 {
		fmt.Fprintf(&b, "Nodes: %s\n", strings.Join(m.NodeIDs, " "))
	}
	fmt.Fprintf(&b, "Cause: %s\n", m.Cause)
	return b.String()
}

const (
	commitAuthorName  = "watchtower"
	commitAuthorEmail = "daemon@local"
	mapFileName       = "map.md"
)

// initialMapContent is the placeholder map.md committed on first open; the
// consolidation pipeline re-renders it at the end of each run.
const initialMapContent = "# Memory Map\n\nEmpty vault — nothing consolidated yet.\n"

// vaultSubdirs are the node directories, one per ID prefix.
var vaultSubdirs = []string{"entities", "episodes", "rollups", "beliefs"}

// subdirFor maps a node ID prefix to its vault subdirectory. IDs become file
// names, so anything that could escape the vault directory is rejected here —
// this is the single validation point for every path built from an ID
// (ReadNode, WriteNodes, redirect_to chasing, reconcile).
func subdirFor(id string) (string, error) {
	if strings.ContainsAny(id, `/\`) || strings.Contains(id, "..") {
		return "", fmt.Errorf("memory: node id %q contains path characters", id)
	}
	switch {
	case strings.HasPrefix(id, "ent_"):
		return "entities", nil
	case strings.HasPrefix(id, "ep_"):
		return "episodes", nil
	case strings.HasPrefix(id, "sum_"):
		return "rollups", nil
	case strings.HasPrefix(id, "bel_"):
		return "beliefs", nil
	default:
		return "", fmt.Errorf("memory: node id %q has unknown prefix", id)
	}
}

// OpenVault opens the vault at path, initializing it on first run: creates
// the directory, runs git init, writes an initial map.md and .gitignore, and
// makes the initial commit. Node subdirectories are created eagerly on every
// open (git tracks only files, so empty directories are worktree-local — no
// .gitkeep placeholders; recreating them here keeps the layout present even
// if the owner deletes an empty one).
func OpenVault(vaultPath string) (*Vault, error) {
	v, err := OpenExistingVault(vaultPath)
	if err == nil {
		return v, nil
	}
	if !errors.Is(err, ErrVaultNotInitialized) {
		return nil, err
	}
	repo, err := initVault(vaultPath)
	if err != nil {
		return nil, err
	}
	if err := ensureSubdirs(vaultPath); err != nil {
		return nil, err
	}
	tightenVaultPerms(vaultPath)
	return &Vault{path: vaultPath, repo: repo}, nil
}

// OpenExistingVault opens an already-initialized vault, returning
// ErrVaultNotInitialized when none exists at the path. Read-only entrypoints
// use it so a read can never git-init a vault as a side effect — creating one
// stays the business of the writing paths (consolidate, seed). Recreating the
// node subdirectories is a worktree convenience, not a git write.
func OpenExistingVault(vaultPath string) (*Vault, error) {
	repo, err := git.PlainOpen(vaultPath)
	switch {
	case err == nil:
		// Existing vault.
	case errors.Is(err, git.ErrRepositoryNotExists):
		return nil, fmt.Errorf("%w (no vault at %s)", ErrVaultNotInitialized, vaultPath)
	default:
		return nil, fmt.Errorf("memory: open vault %s: %w", vaultPath, err)
	}
	if err := ensureSubdirs(vaultPath); err != nil {
		return nil, err
	}
	tightenVaultPerms(vaultPath)
	return &Vault{path: vaultPath, repo: repo}, nil
}

// ensureSubdirs (re)creates the four node directories.
func ensureSubdirs(vaultPath string) error {
	for _, sub := range vaultSubdirs {
		if err := os.MkdirAll(filepath.Join(vaultPath, sub), vaultDirMode); err != nil {
			return fmt.Errorf("memory: create vault dir %s: %w", sub, err)
		}
	}
	return nil
}

// Vault files hold AI-synthesised statements about named people plus
// Gmail- and calendar-derived episodes, so they follow the same owner-only
// modes as the token stores and the database.
const (
	vaultDirMode  os.FileMode = 0o700
	vaultFileMode os.FileMode = 0o600
)

// tightenVaultPerms brings a vault created before these modes existed up to
// them: every node directory to 0700 and every file to 0600. Without it a
// vault seeded under the old 0755/0644 modes would stay world-readable
// forever, since only newly written files pick up the new mode.
//
// The .git directory is tightened to 0700 but not descended into. Its
// contents are the same sensitive material — the node history — so the door
// has to be shut, but the modes of the files behind it are go-git's business:
// it recreates objects and refs at the process umask on every write, so
// rewriting them here would be a fight that has to be re-fought every commit.
// One mode on the directory ends the argument, since nobody can traverse into
// what they cannot enter.
//
// Best-effort: a per-entry failure is logged and the walk carries on to the
// rest of the vault, because a vault that cannot be fully tightened must
// still open. An empty vault visits only its root, which is a clean no-op
// rather than an error.
func tightenVaultPerms(vaultPath string) {
	err := filepath.WalkDir(vaultPath, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if p == vaultPath {
				return err // the root itself is unreadable: nothing to walk
			}
			slog.Warn("skipping unreadable memory vault entry", "path", p, "error", err)
			return nil
		}
		want := vaultFileMode
		if d.IsDir() {
			want = vaultDirMode
		}
		if info, ierr := d.Info(); ierr != nil || info.Mode().Perm() != want {
			if cerr := os.Chmod(p, want); cerr != nil {
				slog.Warn("could not restrict memory vault permissions", "path", p, "error", cerr)
			}
		}
		if d.IsDir() && d.Name() == ".git" {
			return fs.SkipDir
		}
		return nil
	})
	if err != nil {
		slog.Warn("could not walk memory vault to restrict permissions", "path", vaultPath, "error", err)
	}
}

// vaultGitignore keeps editor/OS churn (Obsidian workspace state, Finder
// metadata, temp files) invisible to git status, so it can never be swept
// into a memory(owner-edit) commit.
const vaultGitignore = ".obsidian/\n.DS_Store\n*.tmp\n"

// initVault creates the directory, git-inits it, and commits the initial
// map.md and .gitignore.
func initVault(vaultPath string) (*git.Repository, error) {
	if err := os.MkdirAll(vaultPath, vaultDirMode); err != nil {
		return nil, fmt.Errorf("memory: create vault dir: %w", err)
	}
	repo, err := git.PlainInit(vaultPath, false)
	if err != nil {
		return nil, fmt.Errorf("memory: git init vault: %w", err)
	}
	wt, err := repo.Worktree()
	if err != nil {
		return nil, fmt.Errorf("memory: vault worktree: %w", err)
	}
	for name, content := range map[string]string{
		mapFileName:  initialMapContent,
		".gitignore": vaultGitignore,
	} {
		if err := os.WriteFile(filepath.Join(vaultPath, name), []byte(content), vaultFileMode); err != nil {
			return nil, fmt.Errorf("memory: write initial %s: %w", name, err)
		}
		if _, err := wt.Add(name); err != nil {
			return nil, fmt.Errorf("memory: stage initial %s: %w", name, err)
		}
	}
	msg := CommitMsg{Op: "init", Summary: "initialize vault", Cause: "init"}
	if _, err := wt.Commit(msg.render(), &git.CommitOptions{Author: signature()}); err != nil {
		return nil, fmt.Errorf("memory: initial vault commit: %w", err)
	}
	return repo, nil
}

// Lock takes the cross-process memory lock: a memory.lock file in the vault's
// parent directory (the workspace dir), flock LOCK_EX|LOCK_NB — the same shape
// as the digest pipeline's lock. Every entrypoint that writes the vault or its
// index (Pipeline.Run, CLI seed/reindex) must hold it, so a daemon phase and a
// CLI command can never interleave vault commits and watermark writes. Returns
// the unlock func, or ErrLocked when another run holds the lock.
func (v *Vault) Lock() (func(), error) {
	f, err := os.OpenFile(filepath.Join(filepath.Dir(v.path), "memory.lock"), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, fmt.Errorf("memory: open lock file: %w", err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, ErrLocked
		}
		return nil, fmt.Errorf("memory: flock: %w", err)
	}
	return func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}, nil
}

func signature() *object.Signature {
	return &object.Signature{Name: commitAuthorName, Email: commitAuthorEmail, When: time.Now()}
}

// OwnerEdited reports whether the file at rel (a vault-relative slash path) was
// ever touched by a memory(owner-edit) commit — the owner-touch input to the
// retention score. Cheap by construction: the log is filtered to commits that
// changed this one path, and the walk stops at the first owner-edit. Called
// only for eviction candidates (a bounded set), never for the whole vault.
func (v *Vault) OwnerEdited(rel string) (bool, error) {
	iter, err := v.repo.Log(&git.LogOptions{FileName: &rel})
	if err != nil {
		return false, fmt.Errorf("memory: owner-edit log for %s: %w", rel, err)
	}
	defer iter.Close()

	found := false
	err = iter.ForEach(func(c *object.Commit) error {
		if strings.HasPrefix(c.Message, "memory(owner-edit)") {
			found = true
			return storer.ErrStop
		}
		return nil
	})
	if err != nil {
		return false, fmt.Errorf("memory: owner-edit walk for %s: %w", rel, err)
	}
	return found, nil
}

// OwnerEditedFiles returns the set of vault-relative paths ever touched by a
// memory(owner-edit) commit, across the FULL history — ONE walk, computing
// the exact same "was this file ever owner-edited" fact OwnerEdited answers
// per-call, but for every file at once. Reconcile's bulk pass memoizes
// against this set (see index.go's reconcilePass.ownerEdited) instead of
// paying OwnerEdited's per-file FileName-filtered log walk once per node,
// now that computeNodeImportance runs on every write through ~16+ call
// sites (Task 5b), not just the small bounded eviction-candidate set
// OwnerEdited itself stays scoped for (whole-branch review follow-up, added
// 2026-07-18, MEM-16). The vault history is linear (single author, no
// merges — same invariant LogMemoryCommits relies on), so commit.Stats()'s
// first-parent tree diff is exact, not an approximation.
func (v *Vault) OwnerEditedFiles() (map[string]bool, error) {
	iter, err := v.repo.Log(&git.LogOptions{})
	if err != nil {
		return nil, fmt.Errorf("memory: owner-edited files log: %w", err)
	}
	defer iter.Close()

	files := make(map[string]bool)
	err = iter.ForEach(func(c *object.Commit) error {
		if !strings.HasPrefix(c.Message, "memory(owner-edit)") {
			return nil
		}
		stats, serr := c.Stats()
		if serr != nil {
			return serr
		}
		for _, fs := range stats {
			files[fs.Name] = true
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("memory: owner-edited files walk: %w", err)
	}
	return files, nil
}

// ownerEditedMemo lazily memoizes ONE Vault.OwnerEditedFiles() call, reused
// by every upsertIndexNode call made within a single batch-writing function
// invocation — the reconcilePass.ownerEdited pattern (Task 5d-ii),
// generalized so every production caller that writes more than one node per
// call gets it, not just Reconcile's bulk pass (second whole-branch review
// follow-up, 2026-07-19, MEM-16 addendum: every real upsertIndexNode call
// site turns out to loop over more than one node). A load failure is cached
// too, so every subsequent lookup in the same batch fails the same way
// instead of repeating a failing walk — each caller already handles the
// error via its existing log-and-continue/quarantine path.
type ownerEditedMemo struct {
	v      *Vault
	files  map[string]bool
	err    error
	loaded bool
}

// newOwnerEditedMemo returns a fresh memo scoped to ONE batch-writing call.
// Constructing it does no I/O — the walk happens lazily, on the first
// lookup — so a batch that ends up writing zero nodes never pays for it.
func newOwnerEditedMemo(v *Vault) *ownerEditedMemo {
	return &ownerEditedMemo{v: v}
}

// lookup resolves the owner-touch signal for rel, loading
// v.OwnerEditedFiles() at most once per memo instance. Pass m.lookup wherever
// computeNodeImportance (via upsertIndexNode) needs its
// ownerEdited func(string) (bool, error) parameter.
func (m *ownerEditedMemo) lookup(rel string) (bool, error) {
	if !m.loaded {
		m.files, m.err = m.v.OwnerEditedFiles()
		m.loaded = true
	}
	if m.err != nil {
		return false, m.err
	}
	return m.files[rel], nil
}

// MemoryCommit is one machine memory commit summarized for the weekly
// reflection pass: the op parsed from its "memory(<op>)" subject, the summary
// text, the node ids it touched (from the Nodes: line), and its author time.
type MemoryCommit struct {
	Op      string // beliefs | rewrite | owner-edit (the reflected ops)
	Summary string
	NodeIDs []string
	When    time.Time
}

// reflectedOps is the set of machine op subjects the reflection churn digest
// counts — the belief pass, entity rewrites, and owner vault edits. Extraction
// (extract), seeding (seed), map renders (map), and init are intentionally
// excluded: they are not the "is this area unstable?" signal reflection reads.
var reflectedOps = map[string]bool{"beliefs": true, "rewrite": true, "owner-edit": true}

// LogMemoryCommits walks the vault history newest-first and returns the
// memory(beliefs)/memory(rewrite)/memory(owner-edit) commits whose author time
// is at or after since — the commit-churn input for the weekly reflection pass
// (Reflect). It reads only the commit subject + Nodes line, never a diff
// (sibling of OwnerEdited). The vault history is linear (single author, no
// merges), so the walk stops at the first commit older than since.
func (v *Vault) LogMemoryCommits(since time.Time) ([]MemoryCommit, error) {
	iter, err := v.repo.Log(&git.LogOptions{})
	if err != nil {
		return nil, fmt.Errorf("memory: reflect log: %w", err)
	}
	defer iter.Close()

	var out []MemoryCommit
	err = iter.ForEach(func(c *object.Commit) error {
		if c.Author.When.Before(since) {
			return storer.ErrStop // linear history: nothing older can be in-window
		}
		op, summary, nodes, ok := parseMemoryCommit(c.Message)
		if !ok || !reflectedOps[op] {
			return nil
		}
		out = append(out, MemoryCommit{Op: op, Summary: summary, NodeIDs: nodes, When: c.Author.When})
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("memory: reflect walk: %w", err)
	}
	return out, nil
}

// parseMemoryCommit extracts the op, summary, and Nodes ids from a structured
// machine commit message rendered by CommitMsg.render ("memory(<op>): <summary>\n\nNodes: <id> ...\nCause: ..."). ok is false for a commit whose
// first line is not "memory(<op>): ...".
func parseMemoryCommit(message string) (op, summary string, nodeIDs []string, ok bool) {
	lines := strings.Split(message, "\n")
	if len(lines) == 0 {
		return "", "", nil, false
	}
	head := lines[0]
	if !strings.HasPrefix(head, "memory(") {
		return "", "", nil, false
	}
	closeIdx := strings.Index(head, ")")
	if closeIdx < 0 {
		return "", "", nil, false
	}
	op = head[len("memory("):closeIdx]
	rest := head[closeIdx+1:]
	summary = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(rest), ":"))
	for _, l := range lines[1:] {
		if strings.HasPrefix(l, "Nodes: ") {
			nodeIDs = strings.Fields(strings.TrimPrefix(l, "Nodes: "))
			break
		}
	}
	return op, summary, nodeIDs, true
}

// nodeRelPath is the vault-relative (slash-separated, git-style) path of a
// node file.
func nodeRelPath(id string) (string, error) {
	subdir, err := subdirFor(id)
	if err != nil {
		return "", err
	}
	return path.Join(subdir, id+".md"), nil
}

// ReadNode loads and parses the node with the given ID from the worktree.
func (v *Vault) ReadNode(id string) (Node, error) {
	rel, err := nodeRelPath(id)
	if err != nil {
		return Node{}, err
	}
	raw, err := os.ReadFile(filepath.Join(v.path, filepath.FromSlash(rel)))
	if err != nil {
		return Node{}, fmt.Errorf("memory: read node %s: %w", id, err)
	}
	return ParseNode(raw)
}

// WriteNodes renders each node to its file, stages ONLY those paths, and
// makes exactly one commit. Unrelated worktree dirt (owner edits) is neither
// staged nor committed — it stays in the worktree for CommitOwnerEdits to
// pick up (MEM-03).
func (v *Vault) WriteNodes(nodes []Node, msg CommitMsg) (string, error) {
	if len(nodes) == 0 {
		return "", fmt.Errorf("memory: WriteNodes called with no nodes")
	}
	wt, err := v.repo.Worktree()
	if err != nil {
		return "", fmt.Errorf("memory: vault worktree: %w", err)
	}
	for _, n := range nodes {
		rel, err := nodeRelPath(n.ID)
		if err != nil {
			return "", err
		}
		if err := os.WriteFile(filepath.Join(v.path, filepath.FromSlash(rel)), n.Render(), vaultFileMode); err != nil {
			return "", fmt.Errorf("memory: write node %s: %w", n.ID, err)
		}
		if _, err := wt.Add(rel); err != nil {
			return "", fmt.Errorf("memory: stage node %s: %w", n.ID, err)
		}
	}
	hash, err := wt.Commit(msg.render(), &git.CommitOptions{Author: signature()})
	if err != nil {
		return "", fmt.Errorf("memory: commit nodes: %w", err)
	}
	return hash.String(), nil
}

// WriteFile writes one non-node vault file (v1: the mechanically rendered
// map.md), stages ONLY that path, and makes exactly one commit. Unchanged
// content is a no-op (no write, no commit), so a re-render that produces the
// same bytes adds no history. Nodes must go through WriteNodes. Returns
// whether a commit was made.
func (v *Vault) WriteFile(rel string, content []byte, msg CommitMsg) (bool, error) {
	abs := filepath.Join(v.path, filepath.FromSlash(rel))
	if prev, err := os.ReadFile(abs); err == nil && bytes.Equal(prev, content) {
		return false, nil
	}
	if err := os.WriteFile(abs, content, vaultFileMode); err != nil {
		return false, fmt.Errorf("memory: write %s: %w", rel, err)
	}
	wt, err := v.repo.Worktree()
	if err != nil {
		return false, fmt.Errorf("memory: vault worktree: %w", err)
	}
	if _, err := wt.Add(rel); err != nil {
		return false, fmt.Errorf("memory: stage %s: %w", rel, err)
	}
	if _, err := wt.Commit(msg.render(), &git.CommitOptions{Author: signature()}); err != nil {
		return false, fmt.Errorf("memory: commit %s: %w", rel, err)
	}
	return true, nil
}

// CommitOwnerEdits commits ALL current working-tree changes as a
// memory(owner-edit) commit (MEM-03: owner edits are committed separately
// before any machine write in a run). Returns whether a commit was made; a
// clean tree is a no-op.
func (v *Vault) CommitOwnerEdits() (bool, error) {
	wt, err := v.repo.Worktree()
	if err != nil {
		return false, fmt.Errorf("memory: vault worktree: %w", err)
	}
	status, err := wt.Status()
	if err != nil {
		return false, fmt.Errorf("memory: vault status: %w", err)
	}
	if status.IsClean() {
		return false, nil
	}
	if err := wt.AddWithOptions(&git.AddOptions{All: true}); err != nil {
		return false, fmt.Errorf("memory: stage owner edits: %w", err)
	}
	msg := CommitMsg{Op: "owner-edit", Summary: "manual changes", Cause: "owner-edit"}
	if _, err := wt.Commit(msg.render(), &git.CommitOptions{Author: signature()}); err != nil {
		return false, fmt.Errorf("memory: commit owner edits: %w", err)
	}
	return true, nil
}
