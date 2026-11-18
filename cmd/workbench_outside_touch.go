package cmd

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/workbenchfolders"
)

// outsideNudgeTouch is the touch of one repository outside the bench on
// which the hook tells the agent (spec 2026-11-18 §6.7: the third).
const outsideNudgeTouch = 3

// outsideTouchBudget is how long after its start the synchronous hook may
// still begin a write: its input wait, the database open and its lock waits
// come out of it, well under the entry's 5 s timeout, so Claude Code never
// kills it part-way.
const outsideTouchBudget = 4 * time.Second

// outsideTouchLockWait is how the hook's writes wait for the write lock:
// the synchronous hooks' one short wait, inside outsideTouchBudget.
var outsideTouchLockWait = hookLockWait{}

var workbenchOutsideTouchCmd = &cobra.Command{
	Use:   "outside-touch",
	Short: "Count an agent's touches of folders outside the workbench (a Claude Code hook)",
	Long: "The PostToolUse hook installed by `integrate claude-code --workbench N` for\n" +
		"Read, Edit, Write, MultiEdit, NotebookEdit, Glob and Grep: it maps the tool's path to its\n" +
		"repository root (walking up for .git, at most 64 levels, never on a network mount) and,\n" +
		"for a repository outside every folder of the workbench, counts the touch on the Desktop\n" +
		"terminal's row named by WATCHTOWER_TERMINAL_SESSION_ID. On the third touch of one\n" +
		"repository it prints a context line asking the agent to call suggest_workbench_folder,\n" +
		"once per session and repository; otherwise it prints nothing. It never records the\n" +
		"session's state and always exits 0.",
	PersistentPreRunE:  func(*cobra.Command, []string) error { return nil },
	Args:               cobra.ArbitraryArgs,
	FParseErrWhitelist: cobra.FParseErrWhitelist{UnknownFlags: true},
	RunE: func(cmd *cobra.Command, _ []string) error {
		runOutsideTouchHook(cmd.InOrStdin(), cmd.OutOrStdout(), cmd.ErrOrStderr(), outsideTouchFlagWorkbench)
		return nil
	},
}

var outsideTouchFlagWorkbench string

func init() {
	workbenchOutsideTouchCmd.Flags().StringVar(&outsideTouchFlagWorkbench, workbenchFlag, "", "workbench id")
	workbenchCmd.AddCommand(workbenchOutsideTouchCmd)
}

// outsideTouchInput is the part of a PostToolUse input the hook reads.
type outsideTouchInput struct {
	Cwd       string `json:"cwd"`
	ToolName  string `json:"tool_name"`
	ToolInput struct {
		FilePath     string `json:"file_path"`
		NotebookPath string `json:"notebook_path"`
		Path         string `json:"path"`
	} `json:"tool_input"`
}

// outsideHookOutput is the context line Claude Code adds after the tool's
// result.
type outsideHookOutput struct {
	HookSpecificOutput struct {
		HookEventName     string `json:"hookEventName"`
		AdditionalContext string `json:"additionalContext"`
	} `json:"hookSpecificOutput"`
}

// outsideNudge is the context line of spec §6.7 for root.
func outsideNudge(root string) string {
	return fmt.Sprintf("You keep working in %s, which is not on this workbench. If the task needs it, "+
		"call suggest_workbench_folder(%s, why).", root, root)
}

// runOutsideTouchHook is `workbench outside-touch`: nothing on stdout but
// the nudge, exit 0 always, a real failure one stderr line.
func runOutsideTouchHook(stdin io.Reader, stdout, stderr io.Writer, rawWorkbenchID string) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(stderr, "watchtower: outside touch not counted: panic: %v\n", r)
		}
	}()
	rowID, ok, err := terminalSessionRowID()
	if !ok {
		return
	}
	var root string
	if err == nil {
		root, err = countOutsideTouch(stdin, rowID, rawWorkbenchID)
	}
	if err == nil && root != "" {
		var out outsideHookOutput
		out.HookSpecificOutput.HookEventName = "PostToolUse"
		out.HookSpecificOutput.AdditionalContext = outsideNudge(root)
		var buf bytes.Buffer
		if err = json.NewEncoder(&buf).Encode(out); err == nil {
			_, err = stdout.Write(buf.Bytes())
		}
	}
	if err != nil {
		fmt.Fprintf(stderr, "watchtower: outside touch not counted: %v\n", err)
	}
}

// countOutsideTouch counts the touch the hook input reports and answers the
// repository root to nudge about, "" for none. Every check that needs no
// database runs first, so a touch inside no repository never opens it.
func countOutsideTouch(stdin io.Reader, rowID int64, rawWorkbenchID string) (string, error) {
	workbenchID, err := strconv.ParseInt(strings.TrimSpace(rawWorkbenchID), 10, 64)
	if err != nil || workbenchID <= 0 {
		return "", fmt.Errorf("invalid --workbench %q", briefClip(rawWorkbenchID, 40))
	}
	lock := outsideTouchLockWait.until(lockNow().Add(outsideTouchBudget))
	ctx, cancel := context.WithTimeout(context.Background(), sessionStateInputWait)
	in, err := readHookInputLimit[outsideTouchInput](ctx, stdin, sessionStateStdinLimit)
	cancel()
	if errors.Is(err, io.EOF) {
		return "", nil // a manual run with stdin closed
	}
	if err != nil {
		return "", fmt.Errorf("reading the hook input: %w", err)
	}
	path := touchedPath(in)
	if path == "" {
		return "", nil
	}
	// Without the bench, so a path in no repository (or skipped) never
	// opens the database; the bench's folders are checked against the same
	// root afterwards.
	localMount := outsideLocalMount()
	resolved, root, ok := outsideRoot(path, outsideSkipDirs(), localMount)
	if !ok || sessionRepo(in.Cwd, localMount) == root {
		// The repository the session runs in is the bench's own (its
		// folder or a worktree of it) — the common touch, answered
		// without the database.
		return "", nil
	}
	database, err := outsideTouchOpenDB()
	if err != nil {
		return "", err
	}
	defer database.Close()
	ctx = context.Background()
	bench, others, err := outsideBenches(ctx, database, workbenchID, rowID)
	if err != nil || bench == nil {
		return "", err
	}
	if onTheBench(path, resolved, root, bench) || benchCovers(root, root, others) {
		return "", nil
	}
	declined, err := database.FolderDeclined(ctx, database, workbenchID, root)
	if err != nil || declined {
		return "", err //nolint:wrapcheck // db's message names the workbench
	}
	var touches int
	var nudged, quiet bool
	if err := lock.write(database, func() error {
		var e error
		touches, nudged, quiet, e = database.CountOutsideTouch(ctx, rowID, root)
		return e
	}); err != nil {
		return "", err
	}
	if touches < outsideNudgeTouch || nudged || quiet {
		return "", nil
	}
	claimed := false
	if err := lock.write(database, func() error {
		var e error
		claimed, e = database.ClaimOutsideNudge(ctx, rowID, root)
		return e
	}); err != nil || !claimed {
		return "", err
	}
	return root, nil
}

// outsideTouchOpenDB opens the hook's database (a test seam: the in-repo
// touch never opens it).
var outsideTouchOpenDB = openHookDB

// sessionRepo is the repository root of the hook input's cwd — the place the
// session runs in — resolved the way outsideRoot resolves a touched path
// (never through a non-local mount); "" when there is none.
func sessionRepo(cwd string, localMount func(string) bool) string {
	cwd = hookPath(cwd)
	if cwd == "" {
		return ""
	}
	resolved, ok := resolveLocal(cwd, localMount)
	if !ok {
		return ""
	}
	root, ok := workbenchfolders.RepoRoot(resolved)
	if !ok {
		return ""
	}
	return root
}

// touchedPath is the path the tool call names: file_path (Read, Edit,
// Write, MultiEdit; NotebookEdit's notebook_path), Glob's and Grep's path —
// never a Bash command. A relative path is taken from the input's cwd. ""
// for any other tool, no path, or a path that is not a clean absolute one.
func touchedPath(in outsideTouchInput) string {
	var p string
	switch in.ToolName {
	case "Read", "Edit", "Write", "MultiEdit":
		p = in.ToolInput.FilePath
	case "NotebookEdit":
		p = in.ToolInput.NotebookPath
		if p == "" {
			p = in.ToolInput.FilePath
		}
	case "Glob", "Grep":
		p = in.ToolInput.Path
	}
	if p == "" {
		return ""
	}
	if !filepath.IsAbs(p) {
		cwd := hookPath(in.Cwd)
		if cwd == "" {
			return ""
		}
		p = filepath.Join(cwd, p)
	}
	return hookPath(p)
}

// outsideRoot maps path to the repository root it lies in (spec §6.7, §7
// "hook" row), before the bench is known: never for a path in a skip dir
// (~/.claude, the temp and scratchpad dirs, spelled or resolved) or one that
// is, or resolves through a symlink onto, a mount localMount calls
// non-local — every component's mount is checked before the component is
// probed (resolveLocal), so a network share is never touched —; the walk up
// for `.git` runs on the resolved path and is capped
// (workbenchfolders.RepoRoot). A root that is or holds a skip dir (a
// home-directory repository) is no outside root, and a linked worktree
// counts as its main repository. resolved is the symlink-free path; the
// bench's own checks (onTheBench) follow once its folders are read.
func outsideRoot(path string, skip []string, localMount func(string) bool) (resolved, root string, ok bool) {
	if !filepath.IsAbs(path) {
		return "", "", false
	}
	path = filepath.Clean(path)
	if benchCovers(path, path, skip) {
		return "", "", false
	}
	resolved, ok = resolveLocal(path, localMount)
	if !ok || benchCovers(resolved, resolved, skip) {
		return "", "", false
	}
	root, ok = workbenchfolders.RepoRoot(resolved)
	if !ok || benchCovers(root, root, skip) {
		return "", "", false
	}
	return resolved, root, true
}

// onTheBench reports whether path (spelled or resolved) or its root lies in
// a folder of dirs, or root holds one.
func onTheBench(path, resolved, root string, dirs []string) bool {
	return benchCovers(path, root, dirs) || benchCovers(resolved, root, dirs)
}

// maxLinkHops bounds the symlinks resolveLocal follows (a loop ends there).
const maxLinkHops = 40

// resolveLocal resolves path's symlinks component by component — Lstat and
// Readlink only, never a Stat through a link — and answers false as soon as
// a component, before it is probed, or a link's target lies on a mount
// localMount calls non-local. A missing tail (a file about to be written)
// is kept as spelled.
func resolveLocal(path string, localMount func(string) bool) (string, bool) {
	rest := strings.Split(strings.TrimPrefix(path, "/"), "/")
	cur := "/"
	hops := 0
	for len(rest) > 0 {
		comp := rest[0]
		rest = rest[1:]
		if comp == "" || comp == "." {
			continue
		}
		next := filepath.Join(cur, comp) // ".." is lexical: cur holds no link
		if !localMount(next) {
			return "", false
		}
		fi, err := os.Lstat(next)
		if err != nil {
			return filepath.Join(append([]string{next}, rest...)...), true
		}
		if fi.Mode()&os.ModeSymlink == 0 {
			cur = next
			continue
		}
		if hops++; hops > maxLinkHops {
			return "", false
		}
		target, err := os.Readlink(next)
		if err != nil {
			return "", false
		}
		if !filepath.IsAbs(target) {
			target = filepath.Join(cur, target)
		}
		target = filepath.Clean(target)
		if !localMount(target) {
			return "", false
		}
		rest = append(strings.Split(strings.TrimPrefix(target, "/"), "/"), rest...)
		cur = "/"
	}
	return cur, true
}

// benchCovers reports whether path is one of dirs or inside one, or root
// is one of them or holds one (case-insensitive, APFS).
func benchCovers(path, root string, dirs []string) bool {
	for _, d := range dirs {
		if d == "" {
			continue
		}
		d = filepath.Clean(d)
		if strings.EqualFold(path, d) || pathWithin(path, d) || strings.EqualFold(root, d) || pathWithin(root, d) ||
			pathWithin(d, root) {
			return true
		}
	}
	return false
}

// pathWithin reports whether child lies strictly inside parent, by whole
// path components, ignoring case.
func pathWithin(child, parent string) bool {
	c, p := strings.ToLower(child), strings.ToLower(parent)
	return strings.HasPrefix(c, strings.TrimSuffix(p, string(filepath.Separator))+string(filepath.Separator))
}

// outsideSkipDirs are the dirs the hook never counts: ~/.claude and the
// temp roots Claude Code keeps its scratchpads under (/tmp, os.TempDir(),
// $CLAUDE_CODE_TMPDIR), each also symlink-resolved. A var for tests, whose
// fixtures live under the temp dir.
var outsideSkipDirs = func() []string {
	var cands []string
	if home, err := os.UserHomeDir(); err == nil {
		cands = append(cands, filepath.Join(home, ".claude"))
	}
	cands = append(cands, "/tmp", os.TempDir())
	if d := os.Getenv("CLAUDE_CODE_TMPDIR"); d != "" {
		cands = append(cands, d)
	}
	out := make([]string, 0, 2*len(cands))
	for _, c := range cands {
		out = append(out, filepath.Clean(c))
		if r, err := filepath.EvalSymlinks(c); err == nil {
			out = append(out, r)
		}
	}
	return out
}

// mountEntry is one mount point and whether it is local (MNT_LOCAL).
type mountEntry struct {
	dir   string
	local bool
}

// outsideLocalMount reads the mount table once and answers, for a path,
// whether the mount it lies on is local (its longest mount-point prefix).
// An unreadable table answers false for every path: nothing is walked. A
// var for tests.
var outsideLocalMount = func() func(string) bool {
	mounts, err := readMountTable()
	if err != nil {
		return func(string) bool { return false }
	}
	return func(path string) bool { return mountIsLocal(mounts, path) }
}

// mountIsLocal is whether path's mount in mounts is local: the entry with
// the longest mount point that is path or holds it; false when none does.
func mountIsLocal(mounts []mountEntry, path string) bool {
	best, local := -1, false
	for _, m := range mounts {
		if m.dir != "/" && path != m.dir && !strings.HasPrefix(path, strings.TrimSuffix(m.dir, "/")+"/") {
			continue
		}
		if len(m.dir) > best {
			best, local = len(m.dir), m.local
		}
	}
	return local
}

// outsideBenches reads the folders of the hook's workbench (its live
// folders and its home) and every other bench's live folders. bench is nil
// when rowID is not a row of workbench workbenchID: nothing is counted.
func outsideBenches(ctx context.Context, database *db.DB, workbenchID, rowID int64) (bench, others []string, err error) {
	// A row being deleted counts nothing more.
	var owner int64
	err = database.QueryRowContext(ctx, `SELECT COALESCE(project_id, 0) FROM terminal_sessions WHERE id = ? AND `+db.NotDeletingSQL,
		rowID).Scan(&owner)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && owner != workbenchID) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, wrapOutside(err)
	}
	rows, err := database.QueryContext(ctx, `SELECT workbench_id, folder_path FROM workbench_folders WHERE removed_at IS NULL
		UNION ALL SELECT id, folder_path FROM projects WHERE id = ?`, workbenchID)
	if err != nil {
		return nil, nil, wrapOutside(err)
	}
	defer rows.Close()
	bench = []string{}
	for rows.Next() {
		var wb int64
		var path string
		if err := rows.Scan(&wb, &path); err != nil {
			return nil, nil, wrapOutside(err)
		}
		if wb == workbenchID {
			bench = append(bench, path)
		} else {
			others = append(others, path)
		}
	}
	return bench, others, wrapOutside(rows.Err())
}

func wrapOutside(err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("reading the workbench folders: %w", err)
}
