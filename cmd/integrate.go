package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
)

var integrateCmd = &cobra.Command{
	Use:   "integrate",
	Short: "Wire Watchtower into your coding agent",
	Long: `Install Watchtower's MCP server and skill pack into a coding agent.

Nothing installs itself: this command is the only thing that writes to your
agent's configuration, and 'integrate remove' undoes exactly what it wrote.`,
}

var integrateClaudeCodeCmd = &cobra.Command{
	Use:   "claude-code",
	Short: "Register the MCP server and install the skill pack for Claude Code",
	RunE:  runIntegrateClaudeCode,
}

var integrateCodexCmd = &cobra.Command{
	Use:   "codex --workbench N [--remove]",
	Short: "Set up (or with --remove take out) the codex part of a workbench folder",
	Long: `Installs the workbench skill into the folder's .agents/skills (kept out of git),
removes the Watchtower hooks codex may have imported from Claude Code into the
folder's .codex, and trusts the workbench hooks through codex's own app-server
(an upsert of their hooks.state entries in ~/.codex/config.toml, nothing else).
The MCP server and the hooks themselves are launch flags ('workbench launch-args').
Without a codex binary the trust step is skipped and reported, not failed.

--remove takes out the skill copy, its exclude line and the imported hooks. It
leaves the hook trust in ~/.codex/config.toml: one entry serves every workbench.`,
	Args: cobra.NoArgs,
	RunE: runIntegrateCodex,
}

var integrateStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Report what is installed, missing, or edited",
	RunE:  runIntegrateStatus,
}

var integrateRemoveCmd = &cobra.Command{
	Use:   "remove",
	Short: "Remove the skill pack (and unregister the MCP server)",
	RunE:  runIntegrateRemove,
}

var (
	integrateScope       string
	integratePath        string
	integrateSkillsOnly  bool
	integrateMCPOnly     bool
	integrateWorkbenchID int64
	integrateJSON        bool
	integrateCodexRemove bool
)

func init() {
	rootCmd.AddCommand(integrateCmd)
	integrateCmd.AddCommand(integrateClaudeCodeCmd, integrateCodexCmd, integrateStatusCmd, integrateRemoveCmd)
	integrateCodexCmd.Flags().Int64Var(&integrateWorkbenchID, workbenchFlag, 0, "the Watchtower workbench whose folder to set up (required)")
	integrateCodexCmd.Flags().BoolVar(&integrateCodexRemove, "remove", false, "take the codex part out of the folder instead")

	for _, c := range []*cobra.Command{integrateClaudeCodeCmd, integrateStatusCmd, integrateRemoveCmd} {
		c.Flags().StringVar(&integrateScope, "scope", "user",
			"where skills live: user (~/.claude/skills) or project (./.claude/skills)")
		c.Flags().StringVar(&integratePath, "path", "",
			"explicit skills directory (overrides --scope)")
	}
	// claude-code and remove must agree on what these mean, so they share one
	// registration loop as well as the resolveMCPScope decision below.
	for _, c := range []*cobra.Command{integrateClaudeCodeCmd, integrateRemoveCmd} {
		c.Flags().BoolVar(&integrateSkillsOnly, "skills-only", false,
			"only touch the skill pack; never touch the MCP registration")
		c.Flags().BoolVar(&integrateMCPOnly, "mcp-only", false,
			"only touch the MCP registration; never touch the skill pack")
	}

	for _, c := range []*cobra.Command{integrateClaudeCodeCmd, integrateStatusCmd, integrateRemoveCmd} {
		addWorkbenchIDFlag(c, &integrateWorkbenchID,
			"act on a Watchtower workbench's folder (skill, SessionStart hook, local MCP) instead of the global pack")
	}
	integrateStatusCmd.Flags().BoolVar(&integrateJSON, "json", false, "with --workbench: print the status as JSON")

	// `workbench delete` removes what the install put in the folder (PROJ-02).
	// A package var's initializer runs before any init(), so this replaces
	// cmd/workbench.go's no-op default.
	workbenchRemoveInstall = removeWorkbenchInstall
}

// resolveSkillsDir turns --scope/--path into one directory. An explicit path
// always wins; otherwise user scope is the home directory and project scope
// is the current working directory.
func resolveSkillsDir(scope, explicit string) (string, error) {
	if explicit != "" {
		return explicit, nil
	}
	switch scope {
	case "user":
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("determining home directory: %w", err)
		}
		return filepath.Join(home, ".claude", "skills"), nil
	case "project":
		cwd, err := os.Getwd()
		if err != nil {
			return "", fmt.Errorf("determining working directory: %w", err)
		}
		return filepath.Join(cwd, ".claude", "skills"), nil
	default:
		return "", fmt.Errorf("unknown scope %q: use user or project", scope)
	}
}

func runIntegrateClaudeCode(cmd *cobra.Command, args []string) error {
	if err := checkWorkbenchIDFlags(cmd); err != nil {
		return err
	}
	if integrateWorkbenchID != 0 {
		return runIntegrateForWorkbench(cmd, runWorkbenchInstall)
	}
	scope, err := resolveMCPScope(integrateScope, integratePath, integrateSkillsOnly, integrateMCPOnly)
	if err != nil {
		return err
	}

	if scope.touchSkills {
		results, err := devpack.Install(scope.dir)
		fmt.Printf("Skills (%s):\n", scope.dir)
		printSkillStatuses(results)
		if err != nil {
			return err
		}
	} else {
		fmt.Println("Skipping skill pack install (--mcp-only).")
	}

	if !scope.touchMCP {
		printMCPSkipReason(integrateSkillsOnly, scope.dir, scope.defaultDir, "registration")
		return nil
	}
	return registerMCPWithClaudeCode()
}

func runIntegrateCodex(cmd *cobra.Command, _ []string) error {
	if integrateWorkbenchID <= 0 {
		return usageError("--workbench N is required: the codex part is installed into a workbench folder only")
	}
	if integrateCodexRemove {
		return runIntegrateForWorkbench(cmd, runCodexRemove)
	}
	return runIntegrateForWorkbench(cmd, runCodexInstall)
}

func runIntegrateStatus(cmd *cobra.Command, args []string) error {
	if err := checkWorkbenchIDFlags(cmd); err != nil {
		return err
	}
	if integrateWorkbenchID != 0 {
		return runIntegrateForWorkbench(cmd, func(ctx context.Context, w io.Writer, p *db.Workbench) error {
			return runWorkbenchStatus(ctx, w, p, integrateJSON)
		})
	}
	dir, err := resolveSkillsDir(integrateScope, integratePath)
	if err != nil {
		return err
	}
	results, err := devpack.Status(dir)
	fmt.Printf("Skills (%s):\n", dir)
	printSkillStatuses(results)
	if err != nil {
		return err
	}

	bin, err := os.Executable()
	if err == nil {
		fmt.Printf("\nCLI binary: %s\n", bin)
	}
	return nil
}

func runIntegrateRemove(cmd *cobra.Command, args []string) error {
	if err := checkWorkbenchIDFlags(cmd); err != nil {
		return err
	}
	if integrateWorkbenchID != 0 {
		return runIntegrateForWorkbench(cmd, runWorkbenchRemove)
	}
	scope, err := resolveMCPScope(integrateScope, integratePath, integrateSkillsOnly, integrateMCPOnly)
	if err != nil {
		return err
	}

	if scope.touchSkills {
		results, err := devpack.Remove(scope.dir)
		fmt.Printf("Skills (%s):\n", scope.dir)
		printSkillStatuses(results)
		if err != nil {
			return err
		}
	} else {
		fmt.Println("Skipping skill pack removal (--mcp-only).")
	}

	if !scope.touchMCP {
		printMCPSkipReason(integrateSkillsOnly, scope.dir, scope.defaultDir, "unregistration")
		return nil
	}

	if _, err := exec.LookPath("claude"); err != nil {
		// The skill pack removal above already happened; the absence of the
		// claude CLI just means we cannot also unregister the MCP server
		// ourselves. Report and continue rather than failing the command.
		fmt.Println("\nclaude CLI not found — remove the MCP server yourself with:")
		fmt.Println("  claude mcp remove watchtower")
		return nil //nolint:nilerr
	}
	out, err := exec.Command("claude", "mcp", "remove", "watchtower").CombinedOutput()
	if err != nil {
		fmt.Printf("\nCould not unregister the MCP server (%v). Remove it with:\n", err)
		fmt.Println("  claude mcp remove watchtower")
		fmt.Printf("%s\n", out)
		return nil
	}
	fmt.Println("\nMCP server unregistered.")
	return nil
}

// shouldTouchMCP decides whether "integrate claude-code" should also
// register, or "integrate remove" should also unregister, the global MCP
// server — the shared rule resolveMCPScope applies to both. Skill-pack
// install/removal is scoped by --path/--scope, but MCP registration is
// global, so by default we only touch it when the resolved skills directory
// is the real default location — an explicitly narrowed target (a scratch
// --path, a non-default --scope) must not silently reach outside itself.
// --skills-only/--mcp-only override the default explicitly, in either
// direction.
func shouldTouchMCP(skillsOnly, mcpOnly bool, resolvedDir, defaultDir string) bool {
	if skillsOnly {
		return false
	}
	if mcpOnly {
		return true
	}
	return resolvedDir == defaultDir
}

// mcpScope is the shared decision "integrate claude-code" and "integrate
// remove" must agree on: which directory to act on, and whether this
// invocation should touch the skill pack, the global MCP registration, or
// both. Both subcommands route through resolveMCPScope so they cannot
// quietly drift apart on how --path/--scope/--skills-only/--mcp-only combine
// — a user should never have to remember a different rule for install vs.
// remove.
type mcpScope struct {
	dir, defaultDir       string
	touchSkills, touchMCP bool
}

func resolveMCPScope(scope, explicitPath string, skillsOnly, mcpOnly bool) (mcpScope, error) {
	if skillsOnly && mcpOnly {
		return mcpScope{}, fmt.Errorf("--skills-only and --mcp-only are mutually exclusive")
	}
	dir, err := resolveSkillsDir(scope, explicitPath)
	if err != nil {
		return mcpScope{}, err
	}
	defaultDir, err := resolveSkillsDir("user", "")
	if err != nil {
		return mcpScope{}, err
	}
	return mcpScope{
		dir:         dir,
		defaultDir:  defaultDir,
		touchSkills: !mcpOnly,
		touchMCP:    shouldTouchMCP(skillsOnly, mcpOnly, dir, defaultDir),
	}, nil
}

// printMCPSkipReason explains, for either subcommand, why the MCP half was
// not touched: an explicit --skills-only, or a narrowed --path/--scope that
// must not silently reach the global registration on its own. verb is
// "registration" (install) or "unregistration" (remove).
func printMCPSkipReason(skillsOnly bool, dir, defaultDir, verb string) {
	if skillsOnly {
		fmt.Printf("\nSkipping MCP %s (--skills-only).\n", verb)
		return
	}
	fmt.Printf("\nSkipping MCP %s: %s is not the default Claude Code skills location (%s), and the MCP registration is global — narrowing --path/--scope must not reach outside it.\n", verb, dir, defaultDir)
	fmt.Println("Run with --mcp-only (or without --path/--scope) to reach it.")
}

func printSkillStatuses(results []devpack.SkillStatus) {
	for _, r := range results {
		fmt.Printf("  %-26s %s%s\n", r.Name, r.State, skillStateNote(r.State))
	}
}

func skillStateNote(state devpack.State) string {
	switch state {
	case devpack.StateDrifted:
		return "  (left alone — differs from what we ship)"
	case devpack.StateForeign:
		return "  (not ours — left alone)"
	default:
		// Installed/Updated/Unchanged/Missing/Removed carry no extra
		// annotation — the state name in the column already says it.
		return ""
	}
}

// registerMCPWithClaudeCode registers this binary as the watchtower MCP
// server. When the claude CLI is absent we print the exact command instead of
// failing: the skills are already installed and useful, and the user may be
// configuring a different client.
func registerMCPWithClaudeCode() error {
	bin, err := os.Executable()
	if err != nil {
		return fmt.Errorf("determining the watchtower binary path: %w", err)
	}
	if _, err := exec.LookPath("claude"); err != nil {
		// The skills are already installed and useful on their own, and the
		// user may be configuring a different client — report the command
		// they'd need instead of failing the whole integrate step.
		fmt.Println("\nclaude CLI not found. Register the MCP server yourself with:")
		fmt.Printf("  claude mcp add watchtower -- %s mcp\n", bin)
		return nil //nolint:nilerr
	}
	out, err := exec.Command("claude", "mcp", "add", "watchtower", "--", bin, "mcp").CombinedOutput()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			// claude mcp add's exit code and output do not distinguish
			// "already registered" from a malformed invocation, a corrupted
			// config, or a permissions problem — so say plainly that this
			// did NOT succeed rather than guessing which one it was. The
			// skill pack install above already succeeded and the message
			// below is actionable, so the command still exits 0 instead of
			// failing the whole invocation over the MCP half alone — but
			// nothing here reads as success.
			fmt.Printf("\nMCP registration did not succeed (%v):\n%s\n", err, out)
			fmt.Println("The most common cause is that watchtower is already registered. Check with:")
			fmt.Println("  claude mcp list")
			fmt.Printf("If it is not registered, run:\n  claude mcp add watchtower -- %s mcp\n", bin)
			return nil
		}
		return fmt.Errorf("registering the MCP server: %w", err)
	}
	fmt.Printf("\nMCP server registered: %s mcp\n", bin)
	return nil
}
