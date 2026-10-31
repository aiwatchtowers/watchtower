package handlers

import (
	"path/filepath"
	"strings"

	"github.com/rivo/uniseg"
)

// The allow blocks (the Kit's PermissionAllowBlock raw values, shared through
// WatchtowerKit/Tests/Fixtures/permissions/allow_block_cases.json).
const (
	// AllowBlockClipped: the summary was cut short, so the owner never saw
	// all of the request.
	AllowBlockClipped = "clipped"
	// AllowBlockSettingsPath: an Edit, Write or NotebookEdit of a file that
	// changes Claude Code's, an agent's, git's hooks or the shell's settings.
	AllowBlockSettingsPath = "settingsPath"
)

// AllowSummaryCap is the wire's permission summary cap in grapheme clusters:
// a longer summary reaches the phone shortened. Go↔Go dual path with
// sources.PermissionMaxSummary (TestAllowSummaryCapMatchesTheSlice).
const AllowSummaryCap = 2000

// allowBlockNotes are the phone card's notes and the hub's refusal messages
// (PermissionAllowBlock.note), verbatim.
var allowBlockNotes = map[string]string{
	AllowBlockClipped:      "Shortened — answer on the Mac to allow",
	AllowBlockSettingsPath: "Changes Watchtower or shell settings — answer on the Mac to allow",
}

// pathTools are the tools whose summary is the file path they write.
var pathTools = map[string]bool{"Edit": true, "Write": true, "NotebookEdit": true}

// settingsDirs: a path with one of these components is a settings path.
var settingsDirs = map[string]bool{".claude": true, ".codex": true, ".agents": true}

// settingsFiles: a file with one of these names is a settings path — shell
// rc and profile files, then the ones that run code or steer an agent (ask
// #312).
var settingsFiles = map[string]bool{
	".zshrc": true, ".zshenv": true, ".zprofile": true, ".zlogin": true, ".bashrc": true,
	".bash_profile": true, ".bash_login": true, ".profile": true,
	".mcp.json": true, ".envrc": true, ".gitconfig": true,
}

// settingsPairs: a path with one of these folder/name pairs is a settings
// path.
var settingsPairs = map[[2]string]bool{
	{".git", "hooks"}: true, {".git", "config"}: true, {".watchtower", "workflow.md"}: true,
}

// AllowBlock is the Go twin of the Kit's PermissionAllowBlock.check (#517,
// owner decision in ask #268): why the phone may only deny a request, and
// true; "" and false when it may allow it once. A clipped summary comes
// first, then a path tool writing a settings path.
func AllowBlock(toolName, summary string, clipped bool) (string, bool) {
	if clipped {
		return AllowBlockClipped, true
	}
	if pathTools[toolName] && isSettingsPath(summary) {
		return AllowBlockSettingsPath, true
	}
	return "", false
}

// isSettingsPath: the path has a .claude, .codex or .agents component, lies
// under .git/hooks, is .git/config or .watchtower/workflow.md, or names a file
// of settingsFiles. Compared case-insensitively: the Mac's default file
// system is.
func isSettingsPath(path string) bool {
	var parts []string
	for p := range strings.SplitSeq(strings.ToLower(path), "/") {
		if p != "" {
			parts = append(parts, p)
		}
	}
	for i, p := range parts {
		if settingsDirs[p] {
			return true
		}
		if i > 0 && settingsPairs[[2]string{parts[i-1], p}] {
			return true
		}
	}
	return len(parts) > 0 && settingsFiles[parts[len(parts)-1]]
}

// storedAllowBlock is the allow rule as the hub judges a stored request: the
// summary as the phone got it (shortened by Go's hook flag or the wire's
// cap), plus the Mac's symlink-resolved path (SessionControl.allowBlock).
func storedAllowBlock(toolName, summary string, clippedByGo bool) (string, bool) {
	clipped := clippedByGo || uniseg.GraphemeClusterCount(summary) > AllowSummaryCap
	if block, ok := AllowBlock(toolName, summary, clipped); ok {
		return block, true
	}
	return resolvedSettingsPath(toolName, summary)
}

// resolvedSettingsPath also checks the path with its symlinks resolved: a
// file or folder linked into .claude must not read as an ordinary one. The
// phone cannot resolve it, so only the hub refuses such an allow. An existing
// file resolves whole; the file a Write creates does not exist yet, so its
// folder is resolved and the name kept.
func resolvedSettingsPath(toolName, path string) (string, bool) {
	if !pathTools[toolName] || !strings.HasPrefix(path, "/") {
		return "", false
	}
	var candidates []string
	if whole, err := filepath.EvalSymlinks(path); err == nil {
		candidates = append(candidates, whole)
	}
	if dir, err := filepath.EvalSymlinks(filepath.Dir(path)); err == nil {
		candidates = append(candidates, filepath.Join(dir, filepath.Base(path)))
	}
	for _, c := range candidates {
		if block, ok := AllowBlock(toolName, c, false); ok {
			return block, true
		}
	}
	return "", false
}
