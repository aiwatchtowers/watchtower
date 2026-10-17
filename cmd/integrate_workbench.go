package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/claude"
	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/workbenchmethod"
)

// workbenchCommandRunner runs the claude CLI for the workbench install; tests
// replace it so no test ever execs the real claude.
var workbenchCommandRunner devpack.CommandRunner = execCommandRunner

// workbenchExecutable resolves the watchtower binary path recorded in the
// workbench's hook and MCP registration. A seam (not a bare os.Executable
// call) because looksLikeOurHook (I2) keys on the binary's basename being
// "watchtower" — the real binary always is, but a test binary (e.g.
// "cmd.test") is not, so tests substitute a fixed watchtower-named path.
var workbenchExecutable = os.Executable

// execCommandRunner runs name in dir. "claude" is resolved through
// claude.FindBinary because the Desktop runs this with a GUI-app PATH. A
// non-zero exit is wrapped in devpack.ErrCommandExit; a missing binary
// keeps exec.ErrNotFound in its chain.
func execCommandRunner(ctx context.Context, dir, name string, args ...string) ([]byte, error) {
	bin := name
	if name == "claude" {
		bin = claude.FindBinary("")
	}
	c := exec.CommandContext(ctx, bin, args...)
	c.Dir = dir
	out, err := c.CombinedOutput()
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return out, fmt.Errorf("%w: %s %s: %w", devpack.ErrCommandExit, name, strings.Join(args, " "), err)
	}
	return out, err
}

func workbenchInstallOptions(p *db.Workbench) (devpack.WorkbenchInstallOptions, error) {
	bin, err := workbenchExecutable()
	if err != nil {
		return devpack.WorkbenchInstallOptions{}, fmt.Errorf("determining the watchtower binary path: %w", err)
	}
	return devpack.WorkbenchInstallOptions{WorkbenchID: p.ID, Folder: p.FolderPath, Bin: bin, Run: workbenchCommandRunner}, nil
}

// workbenchSetupOptions is workbenchInstallOptions for an install or resync
// into p's folder (the workbench's, or a session worktree's): the preset
// resolved the way the hooks resolve it — the owner's setting, else that
// folder's workflow.md, else watchtower-flow (spec 2026-10-15 §4.3).
func workbenchSetupOptions(p *db.Workbench) (devpack.WorkbenchInstallOptions, error) {
	o, err := workbenchInstallOptions(p)
	if err != nil {
		return o, err
	}
	o.PresetNone = installPreset(p.ID, p.FolderPath) == workbenchmethod.PresetNone
	return o, nil
}

// installPreset is workbench id's effective preset with folder's
// workflow.md; a database that cannot be opened installs the default
// preset. A var for tests.
var installPreset = func(id int64, folder string) string {
	database, err := openDBFromConfig()
	if err != nil {
		return workbenchmethod.PresetFlow
	}
	defer func() { _ = database.Close() }()
	return workbenchmethod.Resolve(database, id, folder).Preset
}

// removeWorkbenchInstall is `workbench delete`'s folder cleanup (PROJ-02),
// assigned to workbenchRemoveInstall in integrate.go's init: the Claude Code
// install, then the codex part (the hook trust in ~/.codex is shared by
// every folder and stays).
func removeWorkbenchInstall(ctx context.Context, _ *config.Config, p *db.Workbench) error {
	o, err := workbenchInstallOptions(p)
	if err != nil {
		return err
	}
	err = devpack.RemoveWorkbench(ctx, o)
	if !isExistingDir(p.FolderPath) { // the Claude removal already said so
		return err
	}
	_, codexErr := devpack.RemoveCodex(ctx, o)
	return errors.Join(err, codexErr)
}

func isExistingDir(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

// codexShutdownContext is ctx cancelled by SIGINT/SIGTERM too, for every
// path that may start codex's app-server: a cancelled run (the Desktop
// dropping a status call) then still closes the server and kills its
// process group, so nothing it spawned is orphaned.
func codexShutdownContext(ctx context.Context) (context.Context, context.CancelFunc) {
	return notifyShutdownContext(ctx, silentShutdownLogf)
}

// codexAppServerStart starts codex's app-server for the hook trust step. A
// seam: cmd's TestMain stubs it out so no test runs a real codex.
var codexAppServerStart devpack.StartCodexAppServer = codex.StartAppServer

// codexAppServerFor is the app-server factory for o's trust step, with cfg's
// codex_path (nil: loaded from --config) or else codexFindBinary.
func codexAppServerFor(ctx context.Context, cfg *config.Config, o devpack.WorkbenchInstallOptions) func() (codex.AppServer, error) {
	_, srv := codexStatusSources(ctx, cfg, o)
	return srv
}

// codexStatusSources is StatusCodex's resolve and app-server factory, with
// cfg's codex_path (nil: loaded from --config) or else codexFindBinary. A
// config that does not load makes both answer ErrCodexUnresolved.
func codexStatusSources(ctx context.Context, cfg *config.Config, o devpack.WorkbenchInstallOptions) (func() error, func() (codex.AppServer, error)) {
	if cfg == nil {
		var err error
		if cfg, err = config.Load(flagConfig); err != nil {
			err = fmt.Errorf("%w: loading config: %w", devpack.ErrCodexUnresolved, err)
			return func() error { return err }, func() (codex.AppServer, error) { return nil, err }
		}
	}
	return func() error { return devpack.ResolveCodex(cfg, codexFindBinary) },
		devpack.CodexAppServer(ctx, cfg, o.Bin, codexFindBinary, codexAppServerStart)
}

// runCodexInstall is `integrate codex --workbench N`: the skill copy, the
// exclude line, the imported duplicates out, and the hook trust. No codex
// binary is reported, not an error (D5).
func runCodexInstall(ctx context.Context, w io.Writer, p *db.Workbench) error {
	o, err := workbenchSetupOptions(p)
	if err != nil {
		return err
	}
	ctx, cancel := codexShutdownContext(ctx)
	defer cancel()
	st, err := devpack.InstallCodex(ctx, o, codexAppServerFor(ctx, nil, o))
	fmt.Fprintf(w, "Workbench %d (%s), codex:\n", p.ID, p.FolderPath)
	printCodexInstallBody(w, st, err)
	if err != nil {
		fmt.Fprintf(w, "\nProblems:\n  %v\n", err)
	}
	return err
}

// printCodexInstallBody is the per-piece part of a codex install report
// (also `workbench resync`'s).
func printCodexInstallBody(w io.Writer, st devpack.CodexStatus, err error) {
	if st.SkillState != "" {
		fmt.Fprintf(w, "  skill    %s%s (.agents/skills/%s)\n", st.SkillState, skillStateNote(st.SkillState), devpack.WorkbenchSkillName)
	}
	if st.FlowState != "" {
		fmt.Fprintf(w, "  preset   %s%s (.agents/skills/%s)\n", st.FlowState, skillStateNote(st.FlowState), devpack.FlowSkillName)
	}
	switch {
	case st.DuplicatesRemoved:
		fmt.Fprintln(w, "  imported removed the Watchtower hooks codex had imported into .codex")
	case st.ImportedDuplicates:
		fmt.Fprintln(w, "  imported Watchtower hooks codex imported into .codex are still there (see problems)")
	}
	fmt.Fprintf(w, "  trust    %s\n", codexTrustLine(st, err))
}

func codexTrustLine(st devpack.CodexStatus, err error) string {
	switch {
	case !st.Found && errors.Is(err, devpack.ErrCodexUnresolved):
		return "skipped — could not tell which codex to use (see problems)"
	case !st.Found:
		return "skipped — codex not found; install codex and run this again"
	case st.HooksTrusted == nil && errors.Is(err, codex.ErrCodexTrustUnavailable):
		return "unknown — codex could not be asked (see problems)"
	case st.HooksTrusted == nil:
		return "not changed (see problems)"
	case *st.HooksTrusted:
		return "hooks trusted"
	default:
		return "NOT all hooks trusted (see problems)"
	}
}

// runCodexRemove is `integrate codex --workbench N --remove`.
func runCodexRemove(ctx context.Context, w io.Writer, p *db.Workbench) error {
	o, err := workbenchInstallOptions(p)
	if err != nil {
		return err
	}
	sk, rmErr := devpack.RemoveCodex(ctx, o)
	fmt.Fprintf(w, "Workbench %d (%s): codex removal ran.\n", p.ID, p.FolderPath)
	if sk.State == devpack.StateDrifted || sk.State == devpack.StateForeign {
		fmt.Fprintf(w, "  kept: skill %s %s%s (%s)\n", sk.Name, sk.State, skillStateNote(sk.State), sk.Path)
	}
	fmt.Fprintln(w, "  The hook trust in ~/.codex/config.toml is shared by every workbench and was left in place.")
	if rmErr != nil {
		fmt.Fprintf(w, "\nProblems:\n  %v\n", rmErr)
		for _, h := range devpack.OutsideFolderHints(rmErr) {
			fmt.Fprintf(w, "  %s\n", h)
		}
	}
	return rmErr
}

// checkWorkbenchFlags refuses the global-pack flags next to --workbench: the
// workbench install always targets the workbench's own folder.
func checkWorkbenchFlags(scopeChanged bool, explicitPath string, skillsOnly, mcpOnly bool) error {
	if scopeChanged || explicitPath != "" || skillsOnly || mcpOnly {
		return fmt.Errorf("--%s installs into the workbench's own folder; it cannot be combined with --scope, --path, --skills-only or --mcp-only", workbenchFlag)
	}
	return nil
}

type workbenchIntegrateFunc func(ctx context.Context, w io.Writer, p *db.Workbench) error

// runIntegrateForWorkbench runs fn for --workbench N. An install or resync
// of a folder set up before the Workbench rename migrates it to the current
// vocabulary (spec 2026-10-02 §5.4).
func runIntegrateForWorkbench(cmd *cobra.Command, fn workbenchIntegrateFunc) error {
	if err := checkWorkbenchFlags(cmd.Flags().Changed("scope"), integratePath, integrateSkillsOnly, integrateMCPOnly); err != nil {
		return err
	}
	p, err := loadIntegrateWorkbench(integrateWorkbenchID)
	if err != nil {
		return err
	}
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	return fn(ctx, cmd.OutOrStdout(), p)
}

func loadIntegrateWorkbench(id int64) (*db.Workbench, error) {
	database, err := openDBFromConfig()
	if err != nil {
		return nil, err
	}
	defer func() { _ = database.Close() }()
	p, err := database.GetWorkbench(id)
	if err != nil {
		return nil, fmt.Errorf("workbench %d: %w", id, err)
	}
	return p, nil
}

func runWorkbenchInstall(ctx context.Context, w io.Writer, p *db.Workbench) error {
	o, err := workbenchSetupOptions(p)
	if err != nil {
		return err
	}
	rep, err := devpack.InstallWorkbench(ctx, o)
	printWorkbenchInstallReport(w, p, rep, err)
	return err
}

func printWorkbenchInstallReport(w io.Writer, p *db.Workbench, rep devpack.WorkbenchInstallReport, err error) {
	fmt.Fprintf(w, "Workbench %d (%s):\n", p.ID, p.FolderPath)
	printWorkbenchInstallBody(w, rep, err)
	if notes := legacyPermissionNote(rep); notes != "" {
		fmt.Fprintf(w, "\nNote:\n  %s\n", notes)
	}
	if err != nil {
		fmt.Fprintf(w, "\nProblems:\n  %v\n", err)
	}
}

// printWorkbenchInstallBody is the per-piece part of an install report (also
// `workbench resync`'s).
func printWorkbenchInstallBody(w io.Writer, rep devpack.WorkbenchInstallReport, err error) {
	if rep.Skill.Path != "" {
		fmt.Fprintf(w, "  skill    %s%s\n", rep.Skill.State, skillStateNote(rep.Skill.State))
	}
	if rep.Flow.Path != "" {
		fmt.Fprintf(w, "  preset   %s %s%s\n", devpack.FlowSkillName, rep.Flow.State, skillStateNote(rep.Flow.State))
	}
	if rep.SingleFileLayout {
		fmt.Fprintf(w, "  preset   %s\n", singleFileLayoutNote)
	}
	fmt.Fprintf(w, "  hook     %s\n", hookReportLine(rep.HookChanged, err))
	fmt.Fprintf(w, "  cleanup  allow rule %s\n", hookReportLine(rep.CleanupPermissionChanged, err))
	fmt.Fprintf(w, "  exclude  %d line(s) added\n", len(rep.Excluded))
	if rep.MCPRegistered {
		fmt.Fprintf(w, "  mcp      registered (%s, local scope)\n", devpack.WorkbenchMCPServerName)
	} else {
		fmt.Fprintf(w, "  mcp      NOT registered — run:\n    %s\n", rep.MCPCommand)
	}
	printLegacyMigration(w, rep)
}

// printLegacyMigration reports what the install did to a folder set up
// before the Workbench rename (spec 2026-10-02 §5.4); nothing for any other.
// Desktop twin: WorkbenchResynced.legacyLines (WorkbenchCLI.swift) repeats
// these lines, first letter capitalised — change both together.
func printLegacyMigration(w io.Writer, rep devpack.WorkbenchInstallReport) {
	switch rep.LegacySkill.State {
	case devpack.StateRemoved:
		fmt.Fprintf(w, "  legacy   removed the old %s skill\n", devpack.LegacySkillName)
	case devpack.StateDrifted, devpack.StateForeign:
		fmt.Fprintf(w, "  legacy   %s\n", legacySkillKeptNote)
	case devpack.StateMissing, devpack.StateInstalled, devpack.StateUpdated, devpack.StateUnchanged:
		// Missing: there was no old skill. The removal never reports the
		// install states.
	}
	if rep.LegacyHooksReplaced {
		fmt.Fprintln(w, "  legacy   replaced the old hook commands")
	}
	if rep.LegacyMCPRemoved {
		fmt.Fprintf(w, "  legacy   removed the old %s MCP server\n", devpack.LegacyMCPServerName)
	}
}

// legacySkillKeptNote is the report line for an old skill a resync kept:
// edited by the owner, or not ours at all (PROJ-04). It names tools that no
// longer exist, so the owner is told to carry the edits over and delete it.
var legacySkillKeptNote = "Your own copy of the old " + devpack.LegacySkillName + " skill was kept — it names tools that no longer exist, " +
	"so delete .claude/skills/" + devpack.LegacySkillName + " once its edits are carried over; until then Claude Code sees both skills."

// singleFileLayoutNote is the one line for a core skill the owner edited
// before the v10 split (spec 2026-10-15 §4.3): kept, with no preset beside it.
const singleFileLayoutNote = "Your edited skill keeps the old single-file layout; delete it to take the v10 core and preset."

// legacyPermissionNote is the suggestion for the owner's allow rules that
// still name the old server; "" when there are none. The rules are never
// rewritten (spec 2026-10-02 A6).
func legacyPermissionNote(rep devpack.WorkbenchInstallReport) string {
	if rep.LegacyPermissionRules == 0 {
		return ""
	}
	return fmt.Sprintf("%d permission rule(s) in .claude/settings.local.json still name the old %s server; re-allow the tools under %s when Claude Code asks.",
		rep.LegacyPermissionRules, devpack.LegacyMCPServerName, devpack.WorkbenchMCPServerName)
}

func hookReportLine(changed bool, err error) string {
	switch {
	case errors.Is(err, devpack.ErrMalformedSettings):
		return "NOT installed — .claude/settings.local.json is malformed and was left untouched; fix it and run again"
	case changed:
		return "added"
	case err != nil:
		return "not changed (see problems)"
	default:
		return "already present"
	}
}

func runWorkbenchRemove(ctx context.Context, w io.Writer, p *db.Workbench) error {
	o, err := workbenchInstallOptions(p)
	if err != nil {
		return err
	}
	rmErr := devpack.RemoveWorkbench(ctx, o)
	fmt.Fprintf(w, "Workbench %d (%s): removal ran.\n", p.ID, p.FolderPath)
	if st, err := devpack.StatusWorkbench(ctx, o); err != nil {
		fmt.Fprintf(w, "  Could not check what is left installed: %v\n", err)
	} else {
		printWorkbenchLeftovers(w, st)
	}
	if rmErr != nil {
		fmt.Fprintf(w, "\nProblems:\n  %v\n", rmErr)
		for _, h := range devpack.OutsideFolderHints(rmErr) {
			fmt.Fprintf(w, "  %s\n", h)
		}
	}
	return rmErr
}

// printWorkbenchLeftovers names whatever is still installed after a removal —
// in practice only a skill the owner edited (kept by PROJ-04), in either
// vocabulary. Without the claude CLI the registrations cannot be checked,
// so it never claims that nothing is left.
func printWorkbenchLeftovers(w io.Writer, st devpack.WorkbenchStatus) {
	left := false
	for _, s := range []devpack.SkillStatus{st.Skill, st.LegacySkill} {
		if s.State != devpack.StateMissing {
			fmt.Fprintf(w, "  kept: skill %s %s%s (%s)\n", s.Name, s.State, skillStateNote(s.State), s.Path)
			left = true
		}
	}
	if st.Hook {
		fmt.Fprintln(w, "  still present: SessionStart hook")
		left = true
	}
	if st.StopHook {
		fmt.Fprintln(w, "  still present: Stop hook")
		left = true
	}
	if st.StateHooks {
		fmt.Fprintln(w, "  still present: session state hooks")
		left = true
	}
	if st.AskGuard || st.AskToolBlock {
		fmt.Fprintln(w, "  still present: ask guard hooks")
		left = true
	}
	if st.CleanupPermission {
		fmt.Fprintln(w, "  still present: cleanup permission")
		left = true
	}
	if st.CurrentMCP {
		fmt.Fprintf(w, "  still registered: %s\n", devpack.WorkbenchMCPServerName)
		left = true
	}
	if st.LegacyMCP {
		fmt.Fprintf(w, "  still registered: %s\n", devpack.LegacyMCPServerName)
		left = true
	}
	if !st.ClaudeFound {
		fmt.Fprintln(w, "  MCP registrations: unknown (claude CLI not found)")
		left = true
	}
	if !left {
		fmt.Fprintln(w, "  Nothing left installed.")
	}
}

// workbenchStatusJSON is `integrate status --workbench N --json`, read by the
// Desktop's WorkbenchCLI. Keys are a wire contract and keep their pre-rename
// spelling (spec 2026-10-02 A2); new ones are only added. hook, stop_hook
// and mcp count a pre-rename entry too (unchanged contract), although such
// an entry no longer runs: the old hook commands and `mcp --project` only
// answer with the tombstone's Repair line (ask #312). legacy says the folder still holds something a resync would migrate
// (old registration, old hook command, or the old skill as we shipped it) —
// a folder that is not running until it is resynced or repaired;
// legacy_skill is the old skill's state
// ("" = absent, "unchanged", "drifted", "foreign").
type workbenchStatusJSON struct {
	WorkbenchID int64  `json:"project_id"`
	Folder      string `json:"folder"`
	Skill       string `json:"skill"`
	SkillPath   string `json:"skill_path"`
	Hook        bool   `json:"hook"`
	StopHook    bool   `json:"stop_hook"`
	MCP         bool   `json:"mcp"`
	ClaudeFound bool   `json:"claude_found"`
	Legacy      bool   `json:"legacy"`
	LegacySkill string `json:"legacy_skill"`
	// CurrentMCP: the watchtower-workbench registration itself, while mcp
	// also counts the legacy one. Additive: a folder whose new skill is in
	// but whose new registration is not (a resync whose `mcp add` failed)
	// needs a Repair even though mcp reads true.
	CurrentMCP bool `json:"current_mcp"`
	// StateHooks: every session state hook (UserPromptSubmit, Notification,
	// PostToolUse, StopFailure, SubagentStop, SubagentStart) is installed;
	// false with one missing.
	StateHooks bool `json:"state_hooks"`
	// AskGuard: the Stop command hook sending a plain-text request to
	// ask_owner — false for a folder holding only the old marker prompt
	// hook; AskToolBlock: the PreToolUse hook denying AskUserQuestion. A
	// workbench missing either is offered Repair.
	AskGuard     bool `json:"ask_guard"`
	AskToolBlock bool `json:"ask_tool_block"`
	// CleanupPermission: the permissions.allow rule for `watchtower
	// workbench cleanup` (session cleanup §10) is there. Additive; a
	// Re-run Setup adds it to a folder set up before it.
	CleanupPermission bool `json:"cleanup_permission"`
	// Codex is the codex part (spec §4.5). hooks_trusted is null when codex
	// could not be asked (not found, no answer, an unknown protocol);
	// trust_error says why the trust could not be confirmed.
	Codex codexStatusJSON `json:"codex"`
}

// codexStatusJSON: skill is the copy being there; skill_state says whether
// it is current ("unchanged", "drifted" = owner-edited) or a previously
// shipped version ("updated": Repair), "missing" without one.
type codexStatusJSON struct {
	Found              bool   `json:"found"`
	Skill              bool   `json:"skill"`
	SkillState         string `json:"skill_state"`
	HooksTrusted       *bool  `json:"hooks_trusted"`
	ImportedDuplicates bool   `json:"imported_duplicates"`
	TrustError         string `json:"trust_error,omitempty"`
}

// legacySkillState is a legacy skill's state on the wire: "" when there is
// none.
func legacySkillState(s devpack.SkillStatus) string {
	if s.State == devpack.StateMissing {
		return ""
	}
	return string(s.State)
}

func runWorkbenchStatus(ctx context.Context, w io.Writer, p *db.Workbench, asJSON bool) error {
	o, err := workbenchInstallOptions(p)
	if err != nil {
		return err
	}
	st, err := devpack.StatusWorkbench(ctx, o)
	if err != nil {
		return err
	}
	codexCtx, cancel := codexShutdownContext(ctx)
	defer cancel()
	resolve, srv := codexStatusSources(codexCtx, nil, o)
	cs, err := devpack.StatusCodex(codexCtx, o, resolve, srv)
	if err != nil {
		return err
	}
	if asJSON {
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(workbenchStatusJSON{
			WorkbenchID: p.ID, Folder: p.FolderPath,
			Skill: string(st.Skill.State), SkillPath: st.Skill.Path,
			Hook: st.Hook, StopHook: st.StopHook, MCP: st.MCP, ClaudeFound: st.ClaudeFound,
			Legacy: st.Legacy, LegacySkill: legacySkillState(st.LegacySkill),
			CurrentMCP: st.CurrentMCP, StateHooks: st.StateHooks,
			AskGuard: st.AskGuard, AskToolBlock: st.AskToolBlock,
			CleanupPermission: st.CleanupPermission,
			Codex: codexStatusJSON{
				Found: cs.Found, Skill: cs.Skill, SkillState: string(cs.SkillState),
				HooksTrusted: cs.HooksTrusted, ImportedDuplicates: cs.ImportedDuplicates,
				TrustError: cs.TrustError,
			},
		})
	}
	fmt.Fprintf(w, "Workbench %d (%s):\n", p.ID, p.FolderPath)
	fmt.Fprintf(w, "  skill    %s%s\n", st.Skill.State, skillStateNote(st.Skill.State))
	fmt.Fprintf(w, "  hook     %v\n", st.Hook)
	fmt.Fprintf(w, "  stop     %v\n", st.StopHook)
	fmt.Fprintf(w, "  state    %v\n", st.StateHooks)
	fmt.Fprintf(w, "  asks     guard %v, AskUserQuestion block %v\n", st.AskGuard, st.AskToolBlock)
	fmt.Fprintf(w, "  cleanup  allowed %v\n", st.CleanupPermission)
	switch {
	case !st.ClaudeFound:
		fmt.Fprintln(w, "  mcp      unknown — claude CLI not found")
	default:
		fmt.Fprintf(w, "  mcp      %v\n", st.MCP)
	}
	if st.Legacy {
		fmt.Fprintf(w, "  legacy   set up under the old Projects name — its hooks and MCP server no longer run with this Watchtower; "+
			"run 'watchtower workbench resync %d' (the Desktop's Re-run Setup) or Repair install\n", p.ID)
	}
	if s := legacySkillState(st.LegacySkill); s != "" {
		fmt.Fprintf(w, "  old skill %s %s%s (%s)\n", devpack.LegacySkillName, s, skillStateNote(st.LegacySkill.State), st.LegacySkill.Path)
	}
	fmt.Fprintf(w, "  codex    %s\n", codexStatusLine(cs))
	return nil
}

func codexStatusLine(cs devpack.CodexStatus) string {
	trust := "unknown"
	if cs.HooksTrusted != nil {
		trust = fmt.Sprint(*cs.HooksTrusted)
	}
	found := "found"
	if !cs.Found {
		found = "not found"
	}
	line := fmt.Sprintf("%s, skill %s, hooks trusted %s", found, cs.SkillState, trust)
	if cs.ImportedDuplicates {
		line += ", imported Watchtower hooks in .codex (run 'watchtower integrate codex' to clean up)"
	}
	if cs.TrustError != "" {
		line += ", trust check failed: " + cs.TrustError
	}
	return line
}
