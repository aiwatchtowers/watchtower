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
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/devpack"
)

// workbenchCommandRunner runs the claude CLI for the project install; tests
// replace it so no test ever execs the real claude.
var workbenchCommandRunner devpack.CommandRunner = execCommandRunner

// workbenchExecutable resolves the watchtower binary path recorded in the
// project's hook and MCP registration. A seam (not a bare os.Executable
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

// removeWorkbenchInstall is `project delete`'s folder cleanup (PROJ-02),
// assigned to workbenchRemoveInstall in integrate.go's init.
func removeWorkbenchInstall(ctx context.Context, _ *config.Config, p *db.Workbench) error {
	o, err := workbenchInstallOptions(p)
	if err != nil {
		return err
	}
	return devpack.RemoveWorkbench(ctx, o)
}

// checkWorkbenchFlags refuses the global-pack flags next to --workbench: the
// workbench install always targets the workbench's own folder.
func checkWorkbenchFlags(scopeChanged bool, explicitPath string, skillsOnly, mcpOnly bool) error {
	if scopeChanged || explicitPath != "" || skillsOnly || mcpOnly {
		return errors.New("--workbench installs into the workbench's own folder; it cannot be combined with --scope, --path, --skills-only or --mcp-only")
	}
	return nil
}

type workbenchIntegrateFunc func(ctx context.Context, w io.Writer, p *db.Workbench) error

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
	o, err := workbenchInstallOptions(p)
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
	if err != nil {
		fmt.Fprintf(w, "\nProblems:\n  %v\n", err)
	}
}

// printWorkbenchInstallBody is the per-piece part of an install report (also
// `project resync`'s).
func printWorkbenchInstallBody(w io.Writer, rep devpack.WorkbenchInstallReport, err error) {
	if rep.Skill.Path != "" {
		fmt.Fprintf(w, "  skill    %s%s\n", rep.Skill.State, skillStateNote(rep.Skill.State))
	}
	fmt.Fprintf(w, "  hook     %s\n", hookReportLine(rep.HookChanged, err))
	fmt.Fprintf(w, "  exclude  %d line(s) added\n", len(rep.Excluded))
	if rep.MCPRegistered {
		fmt.Fprintf(w, "  mcp      registered (%s, local scope)\n", devpack.WorkbenchMCPServerName)
	} else {
		fmt.Fprintf(w, "  mcp      NOT registered — run:\n    %s\n", rep.MCPCommand)
	}
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
	if st, err := devpack.StatusWorkbench(ctx, o); err == nil {
		printWorkbenchLeftovers(w, st)
	}
	if rmErr != nil {
		fmt.Fprintf(w, "\nProblems:\n  %v\n", rmErr)
	}
	return rmErr
}

// printWorkbenchLeftovers names whatever is still installed after a removal —
// in practice only a skill the owner edited (kept by PROJ-04).
func printWorkbenchLeftovers(w io.Writer, st devpack.WorkbenchStatus) {
	left := false
	if st.Skill.State != devpack.StateMissing {
		fmt.Fprintf(w, "  kept: skill %s%s (%s)\n", st.Skill.State, skillStateNote(st.Skill.State), st.Skill.Path)
		left = true
	}
	if st.Hook {
		fmt.Fprintln(w, "  still present: SessionStart hook")
		left = true
	}
	if st.StopHook {
		fmt.Fprintln(w, "  still present: Stop hook")
		left = true
	}
	if st.MCP {
		fmt.Fprintf(w, "  still registered: %s\n", devpack.WorkbenchMCPServerName)
		left = true
	}
	if !left {
		fmt.Fprintln(w, "  Nothing left installed.")
	}
}

// workbenchStatusJSON is `integrate status --project N --json`, read by the
// Desktop's ProjectCLI (Task 14).
type workbenchStatusJSON struct {
	WorkbenchID int64  `json:"project_id"`
	Folder      string `json:"folder"`
	Skill       string `json:"skill"`
	SkillPath   string `json:"skill_path"`
	Hook        bool   `json:"hook"`
	StopHook    bool   `json:"stop_hook"`
	MCP         bool   `json:"mcp"`
	ClaudeFound bool   `json:"claude_found"`
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
	if asJSON {
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(workbenchStatusJSON{
			WorkbenchID: p.ID, Folder: p.FolderPath,
			Skill: string(st.Skill.State), SkillPath: st.Skill.Path,
			Hook: st.Hook, StopHook: st.StopHook, MCP: st.MCP, ClaudeFound: st.ClaudeFound,
		})
	}
	fmt.Fprintf(w, "Workbench %d (%s):\n", p.ID, p.FolderPath)
	fmt.Fprintf(w, "  skill    %s%s\n", st.Skill.State, skillStateNote(st.Skill.State))
	fmt.Fprintf(w, "  hook     %v\n", st.Hook)
	fmt.Fprintf(w, "  stop     %v\n", st.StopHook)
	switch {
	case !st.ClaudeFound:
		fmt.Fprintln(w, "  mcp      unknown — claude CLI not found")
	default:
		fmt.Fprintf(w, "  mcp      %v\n", st.MCP)
	}
	return nil
}
