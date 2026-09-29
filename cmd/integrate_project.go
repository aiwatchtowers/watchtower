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

// projectCommandRunner runs the claude CLI for the project install; tests
// replace it so no test ever execs the real claude.
var projectCommandRunner devpack.CommandRunner = execCommandRunner

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

func projectInstallOptions(p *db.Project) (devpack.ProjectInstallOptions, error) {
	bin, err := os.Executable()
	if err != nil {
		return devpack.ProjectInstallOptions{}, fmt.Errorf("determining the watchtower binary path: %w", err)
	}
	return devpack.ProjectInstallOptions{ProjectID: p.ID, Folder: p.FolderPath, Bin: bin, Run: projectCommandRunner}, nil
}

// removeProjectInstall is `project delete`'s folder cleanup (PROJ-02),
// assigned to projectRemoveInstall in integrate.go's init.
func removeProjectInstall(ctx context.Context, _ *config.Config, p *db.Project) error {
	o, err := projectInstallOptions(p)
	if err != nil {
		return err
	}
	return devpack.RemoveProject(ctx, o)
}

// checkProjectFlags refuses the global-pack flags next to --project: the
// project install always targets the project's own folder.
func checkProjectFlags(scopeChanged bool, explicitPath string, skillsOnly, mcpOnly bool) error {
	if scopeChanged || explicitPath != "" || skillsOnly || mcpOnly {
		return errors.New("--project installs into the project's own folder; it cannot be combined with --scope, --path, --skills-only or --mcp-only")
	}
	return nil
}

type projectIntegrateFunc func(ctx context.Context, w io.Writer, p *db.Project) error

func runIntegrateForProject(cmd *cobra.Command, fn projectIntegrateFunc) error {
	if err := checkProjectFlags(cmd.Flags().Changed("scope"), integratePath, integrateSkillsOnly, integrateMCPOnly); err != nil {
		return err
	}
	p, err := loadIntegrateProject(integrateProjectID)
	if err != nil {
		return err
	}
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	return fn(ctx, cmd.OutOrStdout(), p)
}

func loadIntegrateProject(id int64) (*db.Project, error) {
	database, err := openDBFromConfig()
	if err != nil {
		return nil, err
	}
	defer func() { _ = database.Close() }()
	p, err := database.GetProject(id)
	if err != nil {
		return nil, fmt.Errorf("project %d: %w", id, err)
	}
	return p, nil
}

func runProjectInstall(ctx context.Context, w io.Writer, p *db.Project) error {
	o, err := projectInstallOptions(p)
	if err != nil {
		return err
	}
	rep, err := devpack.InstallProject(ctx, o)
	printProjectInstallReport(w, p, rep, err)
	return err
}

func printProjectInstallReport(w io.Writer, p *db.Project, rep devpack.ProjectInstallReport, err error) {
	fmt.Fprintf(w, "Project %d (%s):\n", p.ID, p.FolderPath)
	if rep.Skill.Path != "" {
		fmt.Fprintf(w, "  skill    %s%s\n", rep.Skill.State, skillStateNote(rep.Skill.State))
	}
	fmt.Fprintf(w, "  hook     %s\n", hookReportLine(rep.HookChanged, err))
	fmt.Fprintf(w, "  exclude  %d line(s) added\n", len(rep.Excluded))
	if rep.MCPRegistered {
		fmt.Fprintf(w, "  mcp      registered (%s, local scope)\n", devpack.ProjectMCPServerName)
	} else {
		fmt.Fprintf(w, "  mcp      NOT registered — run:\n    %s\n", rep.MCPCommand)
	}
	if err != nil {
		fmt.Fprintf(w, "\nProblems:\n  %v\n", err)
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

func runProjectRemove(ctx context.Context, w io.Writer, p *db.Project) error {
	o, err := projectInstallOptions(p)
	if err != nil {
		return err
	}
	rmErr := devpack.RemoveProject(ctx, o)
	fmt.Fprintf(w, "Project %d (%s): removal ran.\n", p.ID, p.FolderPath)
	if st, err := devpack.StatusProject(ctx, o); err == nil {
		printProjectLeftovers(w, st)
	}
	if rmErr != nil {
		fmt.Fprintf(w, "\nProblems:\n  %v\n", rmErr)
	}
	return rmErr
}

// printProjectLeftovers names whatever is still installed after a removal —
// in practice only a skill the owner edited (kept by PROJ-04).
func printProjectLeftovers(w io.Writer, st devpack.ProjectStatus) {
	left := false
	if st.Skill.State != devpack.StateMissing {
		fmt.Fprintf(w, "  kept: skill %s%s (%s)\n", st.Skill.State, skillStateNote(st.Skill.State), st.Skill.Path)
		left = true
	}
	if st.Hook {
		fmt.Fprintln(w, "  still present: SessionStart hook")
		left = true
	}
	if st.MCP {
		fmt.Fprintf(w, "  still registered: %s\n", devpack.ProjectMCPServerName)
		left = true
	}
	if !left {
		fmt.Fprintln(w, "  Nothing left installed.")
	}
}

// projectStatusJSON is `integrate status --project N --json`, read by the
// Desktop's ProjectCLI (Task 14).
type projectStatusJSON struct {
	ProjectID   int64  `json:"project_id"`
	Folder      string `json:"folder"`
	Skill       string `json:"skill"`
	SkillPath   string `json:"skill_path"`
	Hook        bool   `json:"hook"`
	MCP         bool   `json:"mcp"`
	ClaudeFound bool   `json:"claude_found"`
}

func runProjectStatus(ctx context.Context, w io.Writer, p *db.Project, asJSON bool) error {
	o, err := projectInstallOptions(p)
	if err != nil {
		return err
	}
	st, err := devpack.StatusProject(ctx, o)
	if err != nil {
		return err
	}
	if asJSON {
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(projectStatusJSON{
			ProjectID: p.ID, Folder: p.FolderPath,
			Skill: string(st.Skill.State), SkillPath: st.Skill.Path,
			Hook: st.Hook, MCP: st.MCP, ClaudeFound: st.ClaudeFound,
		})
	}
	fmt.Fprintf(w, "Project %d (%s):\n", p.ID, p.FolderPath)
	fmt.Fprintf(w, "  skill    %s%s\n", st.Skill.State, skillStateNote(st.Skill.State))
	fmt.Fprintf(w, "  hook     %v\n", st.Hook)
	switch {
	case !st.ClaudeFound:
		fmt.Fprintln(w, "  mcp      unknown — claude CLI not found")
	default:
		fmt.Fprintf(w, "  mcp      %v\n", st.MCP)
	}
	return nil
}
