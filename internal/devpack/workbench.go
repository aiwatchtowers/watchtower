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

// The workbench skill is embedded apart from the generic pack: it only makes
// sense inside a folder bound to a Watchtower workbench, so the plain
// `integrate claude-code` (which installs Skills() into ~/.claude/skills)
// must never pick it up.
//
//go:embed workbenchskill/*/SKILL.md
var workbenchSkillFS embed.FS

const (
	// WorkbenchSkillName is the skill's directory name inside the workbench
	// folder's .claude/skills and the frontmatter name it carries.
	WorkbenchSkillName = "watchtower-workbench"
	// WorkbenchMCPServerName is the name the workbench's MCP server is
	// registered under in Claude Code's local scope for the folder.
	WorkbenchMCPServerName = "watchtower-workbench"

	// LegacySkillName and LegacyMCPServerName are what an install from
	// before the Workbench rename (spec 2026-10-02 §5) put in the folder.
	// Nothing installs them any more: install, remove and status only
	// detect them, and install and remove take them out.
	LegacySkillName     = "watchtower-project"
	LegacyMCPServerName = "watchtower-project"
)

var (
	// ErrCommandExit is what a CommandRunner wraps a non-zero exit in, so a
	// "not registered" answer from `claude mcp get` is told apart from a
	// runner that could not start at all.
	ErrCommandExit = errors.New("command exited non-zero")
	// ErrClaudeNotFound means the claude CLI could not be run; the printable
	// command in the report is then the owner's way to finish by hand.
	ErrClaudeNotFound = errors.New("claude CLI not found")
)

// workbenchExcludeLines are the folder-relative paths the install makes
// git-invisible: everything it writes into the folder, nothing else.
var workbenchExcludeLines = []string{
	".claude/skills/" + WorkbenchSkillName + "/",
	".claude/settings.local.json",
}

// legacySkillExcludeLine is the exclude line a pre-rename install wrote for
// its skill. It is dropped from our block only once that directory is gone:
// an owner-edited legacy skill is kept, and stays git-invisible.
const legacySkillExcludeLine = ".claude/skills/" + LegacySkillName + "/"

// CommandRunner runs name with args in dir and returns its combined output.
// A non-zero exit must be reported wrapping ErrCommandExit; a missing binary
// wrapping exec.ErrNotFound.
type CommandRunner func(ctx context.Context, dir, name string, args ...string) ([]byte, error)

// WorkbenchInstallOptions names the workbench, its (symlink-resolved,
// absolute) folder, the watchtower binary the hook and MCP server run, and
// the runner for the claude CLI.
type WorkbenchInstallOptions struct {
	WorkbenchID int64
	Folder      string
	Bin         string
	Run         CommandRunner
}

// WorkbenchInstallReport is what InstallWorkbench did; Excluded holds the
// anchored exclude patterns it added. The Legacy* fields report the
// migration of a folder set up before the Workbench rename (spec 2026-10-02
// §5.4): LegacySkill is what became of the old skill (StateMissing when
// there was none, StateRemoved, StateDrifted/StateForeign when it was
// kept as the owner's, or StateUnchanged when the whole old setup was left
// because the new registration did not go in), LegacyMCPRemoved that the old registration was taken out,
// LegacyHooksReplaced that the old hook commands were replaced in place, and
// LegacyPermissionRules how many allow rules in the folder's
// settings.local.json still name the old server (reported, never changed).
type WorkbenchInstallReport struct {
	Skill         SkillStatus
	HookChanged   bool
	MCPRegistered bool
	MCPCommand    string
	Excluded      []string

	LegacySkill           SkillStatus
	LegacyMCPRemoved      bool
	LegacyHooksReplaced   bool
	LegacyPermissionRules int
}

// WorkbenchStatus is what is installed in a workbench folder right now.
// Hook, StopHook and MCP count the pre-rename entries too — a folder not yet
// resynced keeps working through them (spec 2026-10-02 §5.2). Legacy is set
// while anything a resync would migrate is still there: the old
// registration, an old hook command, or the old skill as we shipped it.
// LegacySkill is the old skill's state: StateMissing, StateUnchanged (ours,
// un-edited), StateDrifted (edited, kept by every resync — PROJ-04) or
// StateForeign. CurrentMCP and LegacyMCP say which registration MCP stands
// for, so a report can name each one that is there.
type WorkbenchStatus struct {
	Skill       SkillStatus
	Hook        bool // the SessionStart hook (the brief)
	StopHook    bool // the Stop hook (the board drift check, PROJ-07)
	MCP         bool // CurrentMCP || LegacyMCP
	ClaudeFound bool

	Legacy      bool
	LegacySkill SkillStatus
	LegacyHooks bool
	CurrentMCP  bool // watchtower-workbench is registered
	LegacyMCP   bool // watchtower-project is registered
}

// WorkbenchSkill returns the embedded watchtower-workbench skill.
func WorkbenchSkill() (name string, body []byte) {
	b, err := workbenchSkillFS.ReadFile(path.Join("workbenchskill", WorkbenchSkillName, "SKILL.md"))
	if err != nil {
		// An embed failure is a build-time defect, not a runtime condition.
		panic("devpack: reading embedded workbench skill: " + err.Error())
	}
	return WorkbenchSkillName, b
}

// workbenchSkill wraps WorkbenchSkill in the pack's Skill shape, so the
// workbench install reuses the same DEV-04 decision (installSkill/planFor) as
// the pack.
func workbenchSkill() Skill {
	name, body := WorkbenchSkill()
	sum := sha256.Sum256(body)
	return Skill{Name: name, Content: string(body), SHA256: hex.EncodeToString(sum[:])}
}

// legacySkill is the pre-rename skill in the pack's Skill shape. It carries
// no content and no digest: we no longer ship it, so the DEV-04 decision
// (planFor) can only match a copy against the shipped-digest sidecar we
// wrote next to it — an un-edited copy is ours to remove, anything else
// (edited, no sidecar, no marker) is the owner's and stays (PROJ-04).
func legacySkill() Skill {
	return Skill{Name: LegacySkillName}
}

// WorkbenchHookCommand is the SessionStart hook's command line (the brief).
func WorkbenchHookCommand(bin string, workbenchID int64) string {
	return sessionStartSpec.command(bin, workbenchID)
}

// WorkbenchStopHookCommand is the Stop hook's command line (the board drift
// check, PROJ-07).
func WorkbenchStopHookCommand(bin string, workbenchID int64) string {
	return stopSpec.command(bin, workbenchID)
}

// WorkbenchMCPCommand is the registration the owner can run by hand when the
// claude CLI is unavailable to us.
func WorkbenchMCPCommand(o WorkbenchInstallOptions) string {
	args := o.mcpAddArgs()
	quoted := make([]string, len(args))
	for i, a := range args {
		quoted[i] = shellQuote(a)
	}
	return "cd " + shellQuote(o.Folder) + " && claude " + strings.Join(quoted, " ")
}

// mcpRemoveCommand is the manual removal of the registration named server.
func mcpRemoveCommand(o WorkbenchInstallOptions, server string) string {
	return "cd " + shellQuote(o.Folder) + " && claude mcp remove --scope local " + server
}

// InstallWorkbench makes the folder ready for Claude Code: exclude lines
// first (so nothing we write ever shows in git status), then the local MCP
// registration, the skill and the SessionStart and Stop hooks. Every step
// runs even when an earlier one failed; the failures come back joined.
//
// It is also the migration of a folder set up before the Workbench rename
// (spec 2026-10-02 §5.4), run only by an explicit install or resync: the old
// skill is removed when it is ours and un-edited, the old hook commands are
// replaced in place, the old registration is removed, and the old skill's
// exclude line goes once its directory is gone. Nothing the owner owns is
// touched (PROJ-04). The registration goes first because the new skill and
// hooks name tools only the new server serves: when it cannot be registered
// (a failed `mcp add`, no claude CLI), a pre-rename folder is left entirely
// on its old skill, hooks and registration — one vocabulary, still working
// through the legacy aliases — rather than half-migrated, and the error says
// so (the report's LegacySkill is then StateUnchanged when the old skill is
// there).
func InstallWorkbench(ctx context.Context, o WorkbenchInstallOptions) (WorkbenchInstallReport, error) {
	if err := o.validate(); err != nil {
		return WorkbenchInstallReport{}, err
	}
	if !isDir(o.Folder) {
		return WorkbenchInstallReport{}, folderGone(o)
	}
	rep := WorkbenchInstallReport{MCPCommand: WorkbenchMCPCommand(o)}
	// A malformed settings file is reported by the hook step; until then its
	// unreadable hooks may be legacy ones, so the claude-not-found hint
	// names the old registration too.
	hadLegacyHooks, hooksErr := HasLegacyHooks(o.Folder, o.WorkbenchID)
	legacySkillDir := filepath.Join(o.skillsDir(), LegacySkillName)
	legacyFolder := hadLegacyHooks || exists(legacySkillDir)
	var errs []error
	var err error
	if rep.Excluded, err = EnsureGitExclude(o.Folder, workbenchExcludeLines); err != nil {
		errs = append(errs, err)
	}
	rep.MCPRegistered, rep.LegacyMCPRemoved, err = registerWorkbenchMCP(ctx, o, legacyFolder || hooksErr != nil)
	if legacyFolder && !rep.MCPRegistered {
		rep.LegacySkill = SkillStatus{Name: LegacySkillName, State: StateMissing}
		if exists(legacySkillDir) {
			rep.LegacySkill.State, rep.LegacySkill.Path = StateUnchanged, filepath.Join(legacySkillDir, "SKILL.md")
		}
		return rep, errors.Join(append(errs, keptLegacySetup(err))...)
	}
	if err != nil {
		errs = append(errs, err)
	}
	if rep.Skill, err = installSkill(o.skillsDir(), workbenchSkill()); err != nil {
		errs = append(errs, err)
	}
	if rep.LegacySkill, err = removeSkill(o.skillsDir(), legacySkill()); err != nil {
		errs = append(errs, err)
	}
	if err := RemoveGitExclude(o.Folder, goneExcludeLines(o.Folder, []string{legacySkillExcludeLine})); err != nil {
		errs = append(errs, err)
	}
	var hookErr error
	if rep.HookChanged, hookErr = installWorkbenchHooks(o); hookErr != nil {
		errs = append(errs, hookErr)
	}
	if hadLegacyHooks {
		stillLegacy, err := HasLegacyHooks(o.Folder, o.WorkbenchID)
		rep.LegacyHooksReplaced = err == nil && !stillLegacy
	}
	// A malformed file is already reported by the hook step.
	if rep.LegacyPermissionRules, err = LegacyPermissionRules(o.Folder); err != nil && !bothMalformed(hookErr, err) {
		errs = append(errs, fmt.Errorf("counting the allow rules that name the old %s server: %w", LegacyMCPServerName, err))
	}
	return rep, errors.Join(errs...)
}

// keptLegacySetup wraps the registration failure of a pre-rename folder that
// was therefore left on its old setup (InstallWorkbench).
func keptLegacySetup(regErr error) error {
	return fmt.Errorf("%w — this folder was set up before the Workbench rename and was left on that setup "+
		"(the old %s skill, hooks and MCP registration kept; nothing of the new setup installed), so it keeps working; "+
		"run the setup again once the %s registration can succeed",
		regErr, LegacySkillName, WorkbenchMCPServerName)
}

// RemoveWorkbench undoes InstallWorkbench (PROJ-02): our two hooks, our
// un-edited skill, the MCP registration, and the exclude line of every path
// that is gone — in both vocabularies, so a folder set up before the
// Workbench rename and never resynced is cleaned up the same way. What the
// owner owns stays (PROJ-04): an edited skill, other settings — and the
// exclude line keeping a surviving file git-invisible.
func RemoveWorkbench(ctx context.Context, o WorkbenchInstallOptions) error {
	if err := o.validate(); err != nil {
		return err
	}
	if !isDir(o.Folder) {
		return folderGone(o)
	}
	var errs []error
	// The hook recognizer matches the pre-rename commands too.
	_, startErr := RemoveSessionStartHook(o.Folder, o.WorkbenchID)
	if startErr != nil {
		errs = append(errs, startErr)
	}
	if _, err := RemoveStopHook(o.Folder, o.WorkbenchID); err != nil && !bothMalformed(startErr, err) {
		errs = append(errs, err)
	}
	for _, s := range []Skill{workbenchSkill(), legacySkill()} {
		if _, err := removeSkill(o.skillsDir(), s); err != nil {
			errs = append(errs, err)
		}
	}
	if err := unregisterWorkbenchMCP(ctx, o); err != nil {
		errs = append(errs, err)
	}
	removeIfEmpty(o.skillsDir())
	removeIfEmpty(filepath.Join(o.Folder, ".claude"))
	lines := append(append([]string{}, workbenchExcludeLines...), legacySkillExcludeLine)
	if err := RemoveGitExclude(o.Folder, goneExcludeLines(o.Folder, lines)); err != nil {
		errs = append(errs, err)
	}
	return errors.Join(errs...)
}

// StatusWorkbench reports skill, hook and MCP state, writing nothing. A
// missing claude CLI is reported through ClaudeFound, not as an error.
func StatusWorkbench(ctx context.Context, o WorkbenchInstallOptions) (WorkbenchStatus, error) {
	if err := o.validate(); err != nil {
		return WorkbenchStatus{}, err
	}
	if !isDir(o.Folder) {
		return WorkbenchStatus{}, folderGone(o)
	}
	ps := WorkbenchStatus{ClaudeFound: true}
	var errs []error
	var err error
	if ps.Skill, err = statusSkill(o.skillsDir(), workbenchSkill()); err != nil {
		errs = append(errs, err)
	}
	if ps.LegacySkill, err = statusLegacySkill(o.skillsDir()); err != nil {
		errs = append(errs, err)
	}
	var startErr error
	if ps.Hook, startErr = HasSessionStartHook(o.Folder, o.WorkbenchID); startErr != nil {
		errs = append(errs, startErr)
	}
	if ps.StopHook, err = HasStopHook(o.Folder, o.WorkbenchID); err != nil && !bothMalformed(startErr, err) {
		errs = append(errs, err)
	}
	// Its only possible failure is the malformed file already reported above.
	ps.LegacyHooks, _ = HasLegacyHooks(o.Folder, o.WorkbenchID)
	ps.CurrentMCP, err = mcpRegistered(ctx, o, WorkbenchMCPServerName)
	if err == nil {
		ps.LegacyMCP, err = mcpRegistered(ctx, o, LegacyMCPServerName)
	}
	switch {
	case errors.Is(err, ErrClaudeNotFound):
		ps.ClaudeFound = false
	case err != nil:
		errs = append(errs, err)
	}
	ps.MCP = ps.CurrentMCP || ps.LegacyMCP
	ps.Legacy = ps.LegacyMCP || ps.LegacyHooks || ps.LegacySkill.State == StateUnchanged
	return ps, errors.Join(errs...)
}

// statusLegacySkill is the pre-rename skill's state: StateUnchanged for our
// un-edited copy (the one a resync removes), otherwise what statusSkill says.
func statusLegacySkill(skillsDir string) (SkillStatus, error) {
	st, err := statusSkill(skillsDir, legacySkill())
	if st.State == StateUpdated { // matches the sidecar we wrote: ours, as shipped
		st.State = StateUnchanged
	}
	return st, err
}

func (o WorkbenchInstallOptions) validate() error {
	switch {
	case o.WorkbenchID <= 0:
		return fmt.Errorf("workbench id must be positive, got %d", o.WorkbenchID)
	case !filepath.IsAbs(o.Folder):
		return fmt.Errorf("workbench folder must be an absolute path, got %q", o.Folder)
	case o.Bin == "":
		return errors.New("the watchtower binary path is empty")
	case o.Run == nil:
		return errors.New("no command runner")
	}
	return nil
}

func (o WorkbenchInstallOptions) skillsDir() string {
	return filepath.Join(o.Folder, ".claude", "skills")
}

// bothMalformed: the second hook step hit the same malformed settings file
// the first one already reported (eventGroupsOf refuses the whole file for
// either event), so its error would only repeat it.
func bothMalformed(first, second error) bool {
	return errors.Is(first, ErrMalformedSettings) && errors.Is(second, ErrMalformedSettings)
}

// installWorkbenchHooks installs the SessionStart and Stop hooks; changed is
// true when either was added or repaired. A malformed settings file is
// reported once, by the first install, and the second is not attempted.
func installWorkbenchHooks(o WorkbenchInstallOptions) (bool, error) {
	started, err := InstallSessionStartHook(o.Folder, WorkbenchHookCommand(o.Bin, o.WorkbenchID), o.WorkbenchID)
	if errors.Is(err, ErrMalformedSettings) {
		return false, err
	}
	stopped, stopErr := InstallStopHook(o.Folder, WorkbenchStopHookCommand(o.Bin, o.WorkbenchID), o.WorkbenchID)
	return started || stopped, errors.Join(err, stopErr)
}

func (o WorkbenchInstallOptions) mcpAddArgs() []string {
	return []string{"mcp", "add", "--scope", "local", WorkbenchMCPServerName, "--",
		o.Bin, "mcp", "--workbench", strconv.FormatInt(o.WorkbenchID, 10)}
}

// registerWorkbenchMCP (re)registers the server in the folder's local scope,
// then removes the pre-rename registration when there is one. An existing
// registration is replaced, so a moved binary is picked up on every install
// (the Desktop's Repair). The old registration goes only once the new one
// is in: a failed add leaves a not-yet-migrated folder with its working old
// server rather than with none. legacyFolder (old hooks or an old skill were
// found, or the hooks could not be read) adds the manual removal of the old registration to a
// claude-not-found error, since the claude CLI cannot be asked whether it is
// there.
func registerWorkbenchMCP(ctx context.Context, o WorkbenchInstallOptions, legacyFolder bool) (registered, legacyRemoved bool, err error) {
	registered, err = registerCurrentMCP(ctx, o)
	switch {
	case errors.Is(err, ErrClaudeNotFound):
		if legacyFolder {
			err = fmt.Errorf("%w — once %s is registered, also remove the old MCP server yourself with: %s",
				err, WorkbenchMCPServerName, mcpRemoveCommand(o, LegacyMCPServerName))
		}
		return false, false, err
	case err != nil:
		if kept, _ := mcpRegistered(ctx, o, LegacyMCPServerName); kept {
			err = fmt.Errorf("%w (the old %s registration was kept, so this folder keeps working until the registration succeeds)",
				err, LegacyMCPServerName)
		}
		return false, false, err
	}
	legacyRemoved, err = removeMCPRegistration(ctx, o, LegacyMCPServerName)
	return registered, legacyRemoved, err
}

func registerCurrentMCP(ctx context.Context, o WorkbenchInstallOptions) (bool, error) {
	if _, err := removeMCPRegistration(ctx, o, WorkbenchMCPServerName); err != nil {
		return false, err
	}
	if out, err := o.Run(ctx, o.Folder, "claude", o.mcpAddArgs()...); err != nil {
		return false, fmt.Errorf("claude mcp add: %w: %s", err, bytes.TrimSpace(out))
	}
	return true, nil
}

// unregisterWorkbenchMCP removes both registrations, the current and the
// pre-rename one, whichever are there.
func unregisterWorkbenchMCP(ctx context.Context, o WorkbenchInstallOptions) error {
	_, err := removeMCPRegistration(ctx, o, WorkbenchMCPServerName)
	if errors.Is(err, ErrClaudeNotFound) {
		return fmt.Errorf("%w — unregister the MCP server yourself with: %s (and, for a folder set up before the Workbench rename: %s)",
			err, mcpRemoveCommand(o, WorkbenchMCPServerName), mcpRemoveCommand(o, LegacyMCPServerName))
	}
	_, legacyErr := removeMCPRegistration(ctx, o, LegacyMCPServerName)
	return errors.Join(err, legacyErr)
}

// removeMCPRegistration removes the local registration named server when
// `claude mcp get` finds it; removed reports that it did. A failed removal
// names the command to run by hand.
func removeMCPRegistration(ctx context.Context, o WorkbenchInstallOptions, server string) (bool, error) {
	registered, err := mcpRegistered(ctx, o, server)
	if err != nil || !registered {
		return false, err
	}
	if out, err := o.Run(ctx, o.Folder, "claude", "mcp", "remove", "--scope", "local", server); err != nil {
		return false, fmt.Errorf("claude mcp remove %s: %w: %s — run it yourself: %s",
			server, err, bytes.TrimSpace(out), mcpRemoveCommand(o, server))
	}
	return true, nil
}

// mcpRegistered asks `claude mcp get` in the folder: exit 0 means
// registered, a non-zero exit means not registered.
func mcpRegistered(ctx context.Context, o WorkbenchInstallOptions, server string) (bool, error) {
	out, err := o.Run(ctx, o.Folder, "claude", "mcp", "get", server)
	switch {
	case err == nil:
		return true, nil
	case errors.Is(err, exec.ErrNotFound):
		return false, ErrClaudeNotFound
	case errors.Is(err, ErrCommandExit):
		return false, nil
	default:
		return false, fmt.Errorf("claude mcp get %s: %w: %s", server, err, bytes.TrimSpace(out))
	}
}

// goneExcludeLines are those of lines whose path no longer exists. A
// surviving path (an edited skill, the owner's own settings) keeps its line.
func goneExcludeLines(folder string, lines []string) []string {
	var gone []string
	for _, l := range lines {
		if !exists(filepath.Join(folder, filepath.FromSlash(strings.TrimSuffix(l, "/")))) {
			gone = append(gone, l)
		}
	}
	return gone
}

// exists reports whether p is there at all (a dangling symlink counts).
func exists(p string) bool {
	_, err := os.Lstat(p)
	return !errors.Is(err, os.ErrNotExist)
}

func folderGone(o WorkbenchInstallOptions) error {
	return fmt.Errorf("workbench folder %s no longer exists; if it comes back, run 'watchtower integrate remove --workbench %d' (or, in that folder: claude mcp remove --scope local %s, and %s for a folder set up before the Workbench rename)",
		o.Folder, o.WorkbenchID, WorkbenchMCPServerName, LegacyMCPServerName)
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
