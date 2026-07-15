package memory

import (
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/object"
)

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

// subdirFor maps a node ID prefix to its vault subdirectory.
func subdirFor(id string) (string, error) {
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
// the directory, runs git init, writes an initial map.md, and makes the
// initial commit. Node subdirectories are created eagerly on every open (git
// tracks only files, so empty directories are worktree-local — no .gitkeep
// placeholders; recreating them here keeps the layout present even if the
// owner deletes an empty one).
func OpenVault(vaultPath string) (*Vault, error) {
	repo, err := git.PlainOpen(vaultPath)
	switch {
	case err == nil:
		// Existing vault.
	case errors.Is(err, git.ErrRepositoryNotExists):
		repo, err = initVault(vaultPath)
		if err != nil {
			return nil, err
		}
	default:
		return nil, fmt.Errorf("memory: open vault %s: %w", vaultPath, err)
	}

	for _, sub := range vaultSubdirs {
		if err := os.MkdirAll(filepath.Join(vaultPath, sub), 0o755); err != nil {
			return nil, fmt.Errorf("memory: create vault dir %s: %w", sub, err)
		}
	}
	return &Vault{path: vaultPath, repo: repo}, nil
}

// initVault creates the directory, git-inits it, and commits the initial
// map.md.
func initVault(vaultPath string) (*git.Repository, error) {
	if err := os.MkdirAll(vaultPath, 0o755); err != nil {
		return nil, fmt.Errorf("memory: create vault dir: %w", err)
	}
	repo, err := git.PlainInit(vaultPath, false)
	if err != nil {
		return nil, fmt.Errorf("memory: git init vault: %w", err)
	}
	if err := os.WriteFile(filepath.Join(vaultPath, mapFileName), []byte(initialMapContent), 0o644); err != nil {
		return nil, fmt.Errorf("memory: write initial map.md: %w", err)
	}
	wt, err := repo.Worktree()
	if err != nil {
		return nil, fmt.Errorf("memory: vault worktree: %w", err)
	}
	if _, err := wt.Add(mapFileName); err != nil {
		return nil, fmt.Errorf("memory: stage initial map.md: %w", err)
	}
	msg := CommitMsg{Op: "init", Summary: "initialize vault", Cause: "init"}
	if _, err := wt.Commit(msg.render(), &git.CommitOptions{Author: signature()}); err != nil {
		return nil, fmt.Errorf("memory: initial vault commit: %w", err)
	}
	return repo, nil
}

func signature() *object.Signature {
	return &object.Signature{Name: commitAuthorName, Email: commitAuthorEmail, When: time.Now()}
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
		if err := os.WriteFile(filepath.Join(v.path, filepath.FromSlash(rel)), n.Render(), 0o644); err != nil {
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

// DirtyWorktree reports whether the working tree differs from HEAD (owner
// edits pending).
func (v *Vault) DirtyWorktree() (bool, error) {
	wt, err := v.repo.Worktree()
	if err != nil {
		return false, fmt.Errorf("memory: vault worktree: %w", err)
	}
	status, err := wt.Status()
	if err != nil {
		return false, fmt.Errorf("memory: vault status: %w", err)
	}
	return !status.IsClean(), nil
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
