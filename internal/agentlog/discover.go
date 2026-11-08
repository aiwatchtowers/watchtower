package agentlog

import (
	"context"
	"os"
	"path/filepath"
	"strings"

	"watchtower/internal/agentfiles"
)

// TranscriptFile is one agent transcript found on disk (agentfiles).
type TranscriptFile = agentfiles.TranscriptFile

// Slug is Claude Code's project directory name for a cwd (agentfiles.Slug).
func Slug(path string) string { return agentfiles.Slug(path) }

// CandidateDirs lists the directories under projectsDir that hold roots'
// transcripts (agentfiles.CandidateDirs).
func CandidateDirs(projectsDir string, roots []string) ([]string, error) {
	return agentfiles.CandidateDirs(projectsDir, roots)
}

// ListTranscripts returns the transcripts in dirs, main files first
// (agentfiles.ListTranscripts).
func ListTranscripts(dirs []string) ([]TranscriptFile, error) {
	return agentfiles.ListTranscripts(dirs)
}

// WorktreeRoots lists the folder's git worktrees other than the folder
// itself (agentfiles.WorktreeRoots).
func WorktreeRoots(ctx context.Context, folder string) []string {
	return agentfiles.WorktreeRoots(ctx, folder)
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
