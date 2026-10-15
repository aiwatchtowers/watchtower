package agentlog

import (
	"bufio"
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// TranscriptFile is one Claude Code transcript found on disk.
type TranscriptFile struct {
	Path, SessionUUID, AgentID string // AgentID "" for main files
	Subagent                   bool
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
				subDir := filepath.Join(dir, name, "subagents")
				subEntries, err := os.ReadDir(subDir)
				if err != nil {
					continue
				}
				for _, se := range subEntries {
					sn := se.Name()
					if se.Type()&os.ModeSymlink != 0 || se.IsDir() || !strings.HasPrefix(sn, "agent-") || !strings.HasSuffix(sn, ".jsonl") {
						continue
					}
					if f, ok := statTranscript(filepath.Join(subDir, sn)); ok {
						f.SessionUUID, f.Subagent = name, true
						f.AgentID = strings.TrimSuffix(strings.TrimPrefix(sn, "agent-"), ".jsonl")
						subs = append(subs, f)
					}
				}
			}
		}
	}
	sort.Slice(mains, func(i, j int) bool { return mains[i].Path < mains[j].Path })
	sort.Slice(subs, func(i, j int) bool { return subs[i].Path < subs[j].Path })
	return append(mains, subs...), nil
}

func statTranscript(path string) (TranscriptFile, bool) {
	fi, err := os.Lstat(path)
	if err != nil || !fi.Mode().IsRegular() {
		return TranscriptFile{}, false
	}
	return TranscriptFile{Path: path, Size: fi.Size(), MTime: fi.ModTime().UTC().Format(time.RFC3339Nano)}, true
}

// WorktreeRoots lists the folder's git worktrees other than the folder
// itself; nil when the folder is not a repository.
func WorktreeRoots(folder string) []string {
	out, err := exec.Command("git", "-C", folder, "worktree", "list", "--porcelain").Output()
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
