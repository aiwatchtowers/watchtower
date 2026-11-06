package agentlog

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// TranscriptFile is one agent transcript found on disk: a Claude Code
// transcript (Agent "") or a Codex rollout (Agent AgentCodex).
type TranscriptFile struct {
	Path, SessionUUID, AgentID string // AgentID "" for main files
	Agent                      string // "" = Claude Code; AgentCodex = a codex rollout
	Subagent                   bool
	AgentType                  string // subagent meta; "" when unknown
	Depth                      int    // subagent meta spawnDepth; 0 = unknown (no meta or no spawnDepth)
	Finished                   *bool  // subagent meta; nil when absent
	Size                       int64
	MTime                      string
}

// Slug is Claude Code's project directory name for a cwd: every
// non-alphanumeric byte becomes '-'.
func Slug(path string) string {
	b := []byte(path)
	for i, c := range b {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {
			b[i] = '-'
		}
	}
	return string(b)
}

// CandidateDirs lists the directories under projectsDir whose name is the
// slug of one of roots or starts with it plus '-' (subfolders, nested
// worktrees). Symlinked entries are skipped (AGENTLOG-04).
func CandidateDirs(projectsDir string, roots []string) ([]string, error) {
	entries, err := os.ReadDir(projectsDir)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range entries {
		if e.Type()&os.ModeSymlink != 0 || !e.IsDir() {
			continue
		}
		for _, r := range roots {
			s := Slug(r)
			if strings.EqualFold(e.Name(), s) || strings.HasPrefix(strings.ToLower(e.Name()), strings.ToLower(s)+"-") {
				out = append(out, filepath.Join(projectsDir, e.Name()))
				break
			}
		}
	}
	return out, nil
}

// ListTranscripts returns the transcripts in dirs: <uuid>.jsonl main files
// first, then <uuid>/subagents/agent-*.jsonl, so a parent session is always
// stored before its subagents' replay check runs.
func ListTranscripts(dirs []string) ([]TranscriptFile, error) {
	var mains, subs []TranscriptFile
	for _, dir := range dirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.Type()&os.ModeSymlink != 0 {
				continue
			}
			name := e.Name()
			if !e.IsDir() && strings.HasSuffix(name, ".jsonl") {
				if f, ok := statTranscript(filepath.Join(dir, name)); ok {
					f.SessionUUID = strings.TrimSuffix(name, ".jsonl")
					mains = append(mains, f)
				}
				continue
			}
			if e.IsDir() {
				subs = append(subs, listSubagentFiles(dir, name)...)
			}
		}
	}
	sort.Slice(mains, func(i, j int) bool { return mains[i].Path < mains[j].Path })
	sort.Slice(subs, func(i, j int) bool { return subs[i].Path < subs[j].Path })
	return append(mains, subs...), nil
}

// listSubagentFiles lists the agent-*.jsonl transcripts under
// <dir>/<sessionDir>/subagents.
func listSubagentFiles(dir, sessionDir string) []TranscriptFile {
	subDir := filepath.Join(dir, sessionDir, "subagents")
	if fi, err := os.Lstat(subDir); err != nil || !fi.IsDir() { // a symlinked dir is not followed (AGENTLOG-04)
		return nil
	}
	subEntries, err := os.ReadDir(subDir)
	if err != nil {
		return nil
	}
	var out []TranscriptFile
	for _, se := range subEntries {
		sn := se.Name()
		if se.Type()&os.ModeSymlink != 0 || se.IsDir() || !strings.HasPrefix(sn, "agent-") || !strings.HasSuffix(sn, ".jsonl") {
			continue
		}
		if f, ok := statTranscript(filepath.Join(subDir, sn)); ok {
			f.SessionUUID, f.Subagent = sessionDir, true
			f.AgentID = strings.TrimSuffix(strings.TrimPrefix(sn, "agent-"), ".jsonl")
			f.AgentType, f.Depth, f.Finished = readSubagentMeta(filepath.Join(subDir, "agent-"+f.AgentID+".meta.json"))
			out = append(out, f)
		}
	}
	return out
}

// readSubagentMeta reads agentType, spawnDepth and finished from the meta file
// beside a subagent transcript. Only those three keys are decoded: the
// description and the rest are never read into memory as fields (AGENTLOG-01).
// A missing, special or invalid file gives zero values.
func readSubagentMeta(path string) (agentType string, depth int, finished *bool) {
	if fi, err := os.Lstat(path); err != nil || !fi.Mode().IsRegular() || fi.Size() > maxMetaBytes {
		return "", 0, nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", 0, nil
	}
	var m struct {
		AgentType  string `json:"agentType"`
		SpawnDepth int    `json:"spawnDepth"`
		Finished   *bool  `json:"finished"`
	}
	if json.Unmarshal(raw, &m) != nil {
		return "", 0, nil
	}
	return m.AgentType, m.SpawnDepth, m.Finished
}

// maxMetaBytes bounds a subagent meta file; real ones are a few hundred bytes.
const maxMetaBytes = 1 << 20

func statTranscript(path string) (TranscriptFile, bool) {
	fi, err := os.Lstat(path)
	if err != nil || !fi.Mode().IsRegular() {
		return TranscriptFile{}, false
	}
	return TranscriptFile{Path: path, Size: fi.Size(), MTime: fi.ModTime().UTC().Format(time.RFC3339Nano)}, true
}

// worktreeListTimeout bounds `git worktree list`: it runs on every daemon
// cycle before the scan budget applies, so a hung git must not stall sync.
const worktreeListTimeout = 5 * time.Second

// WorktreeRoots lists the folder's git worktrees other than the folder
// itself; nil when the folder is not a repository or git fails or times out.
func WorktreeRoots(ctx context.Context, folder string) []string {
	ctx, cancel := context.WithTimeout(ctx, worktreeListTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "git", "-C", folder, "worktree", "list", "--porcelain").Output()
	if err != nil {
		return nil
	}
	self := resolved(folder)
	var roots []string
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		if p, ok := strings.CutPrefix(sc.Text(), "worktree "); ok && !strings.EqualFold(resolved(p), self) {
			roots = append(roots, p)
		}
	}
	return roots
}

// OwnerFolder decides whether a session whose home cwd is home belongs to the
// workbench at thisFolder: the longest workbench folder containing home
// wins; a home in one of thisRoots (worktrees outside the folder) is ours
// when no workbench folder contains it. Returns thisFolder or "".
func OwnerFolder(home string, workbenchFolders []string, thisFolder string, thisRoots []string) string {
	best := ""
	for _, f := range workbenchFolders {
		if within(home, f) && len(f) > len(best) {
			best = f
		}
	}
	if best != "" {
		if strings.EqualFold(best, thisFolder) {
			return thisFolder
		}
		return ""
	}
	for _, r := range thisRoots {
		if within(home, r) {
			return thisFolder
		}
	}
	return ""
}

func within(path, dir string) bool {
	p, d := strings.ToLower(filepath.Clean(path)), strings.ToLower(filepath.Clean(dir))
	return p == d || strings.HasPrefix(p, d+"/")
}

// resolved cleans a path and follows symlinks when it exists (git reports
// real paths, e.g. /private/tmp on macOS).
func resolved(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return filepath.Clean(p)
}

// CodexRow is one codex terminal session of the workbench: its row id, the
// codex session id it runs and the rollout path its SessionStart hook stored
// ("" = none).
type CodexRow struct {
	TerminalSessionID int64
	SessionID         string
	StoredPath        string
}

// DefaultCodexHome is `$CODEX_HOME` when it is set to an absolute path, else
// ~/.codex (Codex's own rule, as cmd's defaultTerminalCodexHome).
func DefaultCodexHome() string {
	if dir := os.Getenv("CODEX_HOME"); filepath.IsAbs(dir) {
		return dir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".codex")
}

// CodexTranscripts finds the rollouts of the workbench's codex rows
// (AGENTLOG-04 as amended in ask #507): a row's stored path when it is an
// absolute regular file named for its session, else
// codexHome/sessions/<y>/<m>/<d>/rollout-*-<id>.jsonl. Nothing is reached
// through a symlink: the stored file, every folder below the sessions root
// and the file itself are checked with Lstat. Rows of other workbenches and
// rollouts with no row are never listed, so never opened. Whether the rollout
// ran in the workbench is decided by the scan (its session_meta cwd).
//
// Interim wiring: A5 moves this discovery onto the session adapter's
// Transcript (internal/sessionagent) and removes it here.
func CodexTranscripts(codexHome string, rows []CodexRow) []TranscriptFile {
	var root string
	if codexHome != "" {
		if r, err := filepath.EvalSymlinks(filepath.Join(codexHome, "sessions")); err == nil {
			root = r
		}
	}
	var out []TranscriptFile
	for _, row := range rows {
		path, ok := locateCodexRollout(root, row)
		if !ok {
			continue
		}
		if f, ok := statTranscript(path); ok {
			f.SessionUUID, f.Agent = row.SessionID, AgentCodex
			out = append(out, f)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out
}

// codexIDRe is a codex session id (a UUID), the only shape put into a glob.
var codexIDRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

func locateCodexRollout(root string, row CodexRow) (string, bool) {
	if !codexIDRe.MatchString(row.SessionID) {
		return "", false
	}
	suffix := "-" + row.SessionID + ".jsonl"
	if p := row.StoredPath; filepath.IsAbs(p) && strings.HasPrefix(filepath.Base(p), "rollout-") && strings.HasSuffix(p, suffix) {
		if fi, err := os.Lstat(p); err == nil && fi.Mode().IsRegular() {
			return p, true
		}
	}
	if root == "" {
		return "", false
	}
	matches, _ := filepath.Glob(filepath.Join(root, "*", "*", "*", "rollout-*"+suffix))
	sort.Strings(matches)
	for _, m := range matches {
		if noSymlinkBelow(root, m) {
			return m, true
		}
	}
	return "", false
}

// noSymlinkBelow reports whether every path element of p below root (the
// file included) is a real directory or regular file, not a symlink.
func noSymlinkBelow(root, p string) bool {
	rel, err := filepath.Rel(root, p)
	if err != nil || rel == "." || strings.HasPrefix(rel, "..") {
		return false
	}
	cur := root
	parts := strings.Split(rel, string(filepath.Separator))
	for i, part := range parts {
		cur = filepath.Join(cur, part)
		fi, err := os.Lstat(cur)
		if err != nil || fi.Mode()&os.ModeSymlink != 0 {
			return false
		}
		if last := i == len(parts)-1; last != fi.Mode().IsRegular() || (!last && !fi.IsDir()) {
			return false
		}
	}
	return true
}
