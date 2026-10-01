package devpack

import (
	"bytes"
	"context"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strconv"
	"strings"
)

// The project skill is embedded apart from the generic pack: it only makes
// sense inside a folder bound to a Watchtower project, so the plain
// `integrate claude-code` (which installs Skills() into ~/.claude/skills)
// must never pick it up.
//
//go:embed projectskill/*/SKILL.md
var projectSkillFS embed.FS

// ProjectSkillName is the skill's directory name inside the project folder's
// .claude/skills and the frontmatter name it carries.
const ProjectSkillName = "watchtower-project"

// ProjectMCPServerName is the name the project's MCP server is registered
// under in Claude Code's local scope for the folder.
const ProjectMCPServerName = "watchtower-project"

var (
	// ErrCommandExit is what a CommandRunner wraps a non-zero exit in, so a
	// "not registered" answer from `claude mcp get` is told apart from a
	// runner that could not start at all.
	ErrCommandExit = errors.New("command exited non-zero")
	// ErrClaudeNotFound means the claude CLI could not be run; the printable
	// command in the report is then the owner's way to finish by hand.
	ErrClaudeNotFound = errors.New("claude CLI not found")
)

// projectExcludeLines are the folder-relative paths the install makes
// git-invisible: everything it writes into the folder, nothing else.
var projectExcludeLines = []string{
	".claude/skills/" + ProjectSkillName + "/",
	".claude/settings.local.json",
}

// CommandRunner runs name with args in dir and returns its combined output.
// A non-zero exit must be reported wrapping ErrCommandExit; a missing binary
// wrapping exec.ErrNotFound.
type CommandRunner func(ctx context.Context, dir, name string, args ...string) ([]byte, error)

// ProjectInstallOptions names the project, its (symlink-resolved, absolute)
// folder, the watchtower binary the hook and MCP server run, and the runner
// for the claude CLI.
type ProjectInstallOptions struct {
	ProjectID int64
	Folder    string
	Bin       string
	Run       CommandRunner
}

// ProjectInstallReport is what InstallProject did; Excluded holds the
// anchored exclude patterns it added.
type ProjectInstallReport struct {
	Skill         SkillStatus
	HookChanged   bool
	MCPRegistered bool
	MCPCommand    string
	Excluded      []string
}

// ProjectStatus is what is installed in a project folder right now.
type ProjectStatus struct {
	Skill       SkillStatus
	Hook        bool // the SessionStart hook (the brief)
	StopHook    bool // the Stop hook (the board drift check, PROJ-07)
	MCP         bool
	ClaudeFound bool
}

// ProjectSkill returns the embedded watchtower-project skill.
func ProjectSkill() (name string, body []byte) {
	b, err := projectSkillFS.ReadFile(path.Join("projectskill", ProjectSkillName, "SKILL.md"))
	if err != nil {
		// An embed failure is a build-time defect, not a runtime condition.
		panic("devpack: reading embedded project skill: " + err.Error())
	}
	return ProjectSkillName, b
}

// projectSkill wraps ProjectSkill in the pack's Skill shape, so the project
// install reuses the same DEV-04 decision (installSkill/planFor) as the pack.
func projectSkill() Skill {
	name, body := ProjectSkill()
	sum := sha256.Sum256(body)
	return Skill{Name: name, Content: string(body), SHA256: hex.EncodeToString(sum[:])}
}

// ProjectHookCommand is the SessionStart hook's command line (the brief).
func ProjectHookCommand(bin string, projectID int64) string {
	return sessionStartSpec.command(bin, projectID)
}

// ProjectStopHookCommand is the Stop hook's command line (the board drift
// check, PROJ-07).
func ProjectStopHookCommand(bin string, projectID int64) string {
	return stopSpec.command(bin, projectID)
}

// ProjectMCPCommand is the registration the owner can run by hand when the
// claude CLI is unavailable to us.
func ProjectMCPCommand(o ProjectInstallOptions) string {
	args := o.mcpAddArgs()
	quoted := make([]string, len(args))
	for i, a := range args {
		quoted[i] = shellQuote(a)
	}
	return "cd " + shellQuote(o.Folder) + " && claude " + strings.Join(quoted, " ")
}

// InstallProject makes the folder ready for Claude Code: exclude lines
// first (so nothing we write ever shows in git status), then the skill, the
// SessionStart and Stop hooks and the local MCP registration. Every step runs even
// when an earlier one failed; the failures come back joined.
func InstallProject(ctx context.Context, o ProjectInstallOptions) (ProjectInstallReport, error) {
	if err := o.validate(); err != nil {
		return ProjectInstallReport{}, err
	}
	if !isDir(o.Folder) {
		return ProjectInstallReport{}, folderGone(o)
	}
	rep := ProjectInstallReport{MCPCommand: ProjectMCPCommand(o)}
	var errs []error
	var err error
	if rep.Excluded, err = EnsureGitExclude(o.Folder, projectExcludeLines); err != nil {
		errs = append(errs, err)
	}
	if rep.Skill, err = installSkill(o.skillsDir(), projectSkill()); err != nil {
		errs = append(errs, err)
	}
	if rep.HookChanged, err = installProjectHooks(o); err != nil {
		errs = append(errs, err)
	}
	if rep.MCPRegistered, err = registerProjectMCP(ctx, o); err != nil {
		errs = append(errs, err)
	}
	return rep, errors.Join(errs...)
}

// RemoveProject undoes InstallProject (PROJ-02): our two hooks, our un-edited
// skill, the MCP registration, and the exclude line of every path that is
// gone. What the owner owns stays (PROJ-04): an edited skill, other
// settings — and the exclude line keeping a surviving file git-invisible.
func RemoveProject(ctx context.Context, o ProjectInstallOptions) error {
	if err := o.validate(); err != nil {
		return err
	}
	if !isDir(o.Folder) {
		return folderGone(o)
	}
	var errs []error
	_, startErr := RemoveSessionStartHook(o.Folder, o.ProjectID)
	if startErr != nil {
		errs = append(errs, startErr)
	}
	if _, err := RemoveStopHook(o.Folder, o.ProjectID); err != nil && !bothMalformed(startErr, err) {
		errs = append(errs, err)
	}
	if _, err := removeSkill(o.skillsDir(), projectSkill()); err != nil {
		errs = append(errs, err)
	}
	if err := unregisterProjectMCP(ctx, o); err != nil {
		errs = append(errs, err)
	}
	removeIfEmpty(o.skillsDir())
	removeIfEmpty(filepath.Join(o.Folder, ".claude"))
	if err := RemoveGitExclude(o.Folder, goneExcludeLines(o.Folder)); err != nil {
		errs = append(errs, err)
	}
	return errors.Join(errs...)
}

// StatusProject reports skill, hook and MCP state, writing nothing. A
// missing claude CLI is reported through ClaudeFound, not as an error.
func StatusProject(ctx context.Context, o ProjectInstallOptions) (ProjectStatus, error) {
	if err := o.validate(); err != nil {
		return ProjectStatus{}, err
	}
	if !isDir(o.Folder) {
		return ProjectStatus{}, folderGone(o)
	}
	ps := ProjectStatus{ClaudeFound: true}
	var errs []error
	var err error
	if ps.Skill, err = statusSkill(o.skillsDir(), projectSkill()); err != nil {
		errs = append(errs, err)
	}
	var startErr error
	if ps.Hook, startErr = HasSessionStartHook(o.Folder, o.ProjectID); startErr != nil {
		errs = append(errs, startErr)
	}
	if ps.StopHook, err = HasStopHook(o.Folder, o.ProjectID); err != nil && !bothMalformed(startErr, err) {
		errs = append(errs, err)
	}
	ps.MCP, err = projectMCPRegistered(ctx, o)
	switch {
	case errors.Is(err, ErrClaudeNotFound):
		ps.ClaudeFound = false
	case err != nil:
		errs = append(errs, err)
	}
	return ps, errors.Join(errs...)
}

func (o ProjectInstallOptions) validate() error {
	switch {
	case o.ProjectID <= 0:
		return fmt.Errorf("project id must be positive, got %d", o.ProjectID)
	case !filepath.IsAbs(o.Folder):
		return fmt.Errorf("project folder must be an absolute path, got %q", o.Folder)
	case o.Bin == "":
		return errors.New("the watchtower binary path is empty")
	case o.Run == nil:
		return errors.New("no command runner")
	}
	return nil
}

func (o ProjectInstallOptions) skillsDir() string {
	return filepath.Join(o.Folder, ".claude", "skills")
}

// bothMalformed: the second hook step hit the same malformed settings file
// the first one already reported (eventGroupsOf refuses the whole file for
// either event), so its error would only repeat it.
func bothMalformed(first, second error) bool {
	return errors.Is(first, ErrMalformedSettings) && errors.Is(second, ErrMalformedSettings)
}

// installProjectHooks installs the SessionStart and Stop hooks; changed is
// true when either was added or repaired. A malformed settings file is
// reported once, by the first install, and the second is not attempted.
func installProjectHooks(o ProjectInstallOptions) (bool, error) {
	started, err := InstallSessionStartHook(o.Folder, ProjectHookCommand(o.Bin, o.ProjectID), o.ProjectID)
	if errors.Is(err, ErrMalformedSettings) {
		return false, err
	}
	stopped, stopErr := InstallStopHook(o.Folder, ProjectStopHookCommand(o.Bin, o.ProjectID), o.ProjectID)
	return started || stopped, errors.Join(err, stopErr)
}

func (o ProjectInstallOptions) mcpAddArgs() []string {
	return []string{"mcp", "add", "--scope", "local", ProjectMCPServerName, "--",
		o.Bin, "mcp", "--project", strconv.FormatInt(o.ProjectID, 10)}
}

// registerProjectMCP (re)registers the server in the folder's local scope.
// An existing registration is replaced, so a moved binary is picked up on
// every install (the Desktop's Repair).
func registerProjectMCP(ctx context.Context, o ProjectInstallOptions) (bool, error) {
	registered, err := projectMCPRegistered(ctx, o)
	if err != nil {
		return false, err
	}
	if registered {
		if out, err := o.Run(ctx, o.Folder, "claude", "mcp", "remove", "--scope", "local", ProjectMCPServerName); err != nil {
			return false, fmt.Errorf("claude mcp remove: %w: %s", err, bytes.TrimSpace(out))
		}
	}
	if out, err := o.Run(ctx, o.Folder, "claude", o.mcpAddArgs()...); err != nil {
		return false, fmt.Errorf("claude mcp add: %w: %s", err, bytes.TrimSpace(out))
	}
	return true, nil
}

func unregisterProjectMCP(ctx context.Context, o ProjectInstallOptions) error {
	registered, err := projectMCPRegistered(ctx, o)
	if errors.Is(err, ErrClaudeNotFound) {
		return fmt.Errorf("%w — unregister the MCP server yourself with: cd %s && claude mcp remove --scope local %s",
			err, shellQuote(o.Folder), ProjectMCPServerName)
	}
	if err != nil || !registered {
		return err
	}
	if out, err := o.Run(ctx, o.Folder, "claude", "mcp", "remove", "--scope", "local", ProjectMCPServerName); err != nil {
		return fmt.Errorf("claude mcp remove: %w: %s", err, bytes.TrimSpace(out))
	}
	return nil
}

// projectMCPRegistered asks `claude mcp get` in the folder: exit 0 means
// registered, a non-zero exit means not registered.
func projectMCPRegistered(ctx context.Context, o ProjectInstallOptions) (bool, error) {
	out, err := o.Run(ctx, o.Folder, "claude", "mcp", "get", ProjectMCPServerName)
	switch {
	case err == nil:
		return true, nil
	case errors.Is(err, exec.ErrNotFound):
		return false, ErrClaudeNotFound
	case errors.Is(err, ErrCommandExit):
		return false, nil
	default:
		return false, fmt.Errorf("claude mcp get: %w: %s", err, bytes.TrimSpace(out))
	}
}

// goneExcludeLines are the exclude lines whose path no longer exists. A
// surviving path (an edited skill, the owner's own settings) keeps its line.
func goneExcludeLines(folder string) []string {
	var gone []string
	for _, l := range projectExcludeLines {
		p := filepath.Join(folder, filepath.FromSlash(strings.TrimSuffix(l, "/")))
		if _, err := os.Lstat(p); errors.Is(err, os.ErrNotExist) {
			gone = append(gone, l)
		}
	}
	return gone
}

func folderGone(o ProjectInstallOptions) error {
	return fmt.Errorf("project folder %s no longer exists; if it comes back, run 'watchtower integrate remove --project %d' (or, in that folder: claude mcp remove --scope local %s)",
		o.Folder, o.ProjectID, ProjectMCPServerName)
}

func isDir(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

// removeIfEmpty drops a directory only when nothing is left in it.
func removeIfEmpty(dir string) {
	if entries, err := os.ReadDir(dir); err == nil && len(entries) == 0 {
		_ = os.Remove(dir)
	}
}

// shellQuote single-quotes s unless it is made only of characters no POSIX
// shell treats specially.
func shellQuote(s string) string {
	if s != "" && strings.IndexFunc(s, unsafeShellRune) < 0 {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func unsafeShellRune(r rune) bool {
	if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
		return false
	}
	return !strings.ContainsRune("/._-+:@%,=", r)
}
