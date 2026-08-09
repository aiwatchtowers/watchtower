package cmd

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/spf13/cobra"

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
	integrateScope      string
	integratePath       string
	integrateSkillsOnly bool
	integrateMCPOnly    bool
)

func init() {
	rootCmd.AddCommand(integrateCmd)
	integrateCmd.AddCommand(integrateClaudeCodeCmd, integrateStatusCmd, integrateRemoveCmd)

	for _, c := range []*cobra.Command{integrateClaudeCodeCmd, integrateStatusCmd, integrateRemoveCmd} {
		c.Flags().StringVar(&integrateScope, "scope", "user",
			"where skills live: user (~/.claude/skills) or project (./.claude/skills)")
		c.Flags().StringVar(&integratePath, "path", "",
			"explicit skills directory (overrides --scope)")
	}
	integrateClaudeCodeCmd.Flags().BoolVar(&integrateSkillsOnly, "skills-only", false,
		"install the skill pack without registering the MCP server")
	integrateRemoveCmd.Flags().BoolVar(&integrateSkillsOnly, "skills-only", false,
		"remove only the skill pack; never touch the MCP registration")
	integrateRemoveCmd.Flags().BoolVar(&integrateMCPOnly, "mcp-only", false,
		"unregister only the MCP server; never touch the skill pack")
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
	dir, err := resolveSkillsDir(integrateScope, integratePath)
	if err != nil {
		return err
	}
	results, err := devpack.Install(dir)
	if err != nil {
		return err
	}
	fmt.Printf("Skills (%s):\n", dir)
	printSkillStatuses(results)

	if integrateSkillsOnly {
		return nil
	}
	return registerMCPWithClaudeCode()
}

func runIntegrateStatus(cmd *cobra.Command, args []string) error {
	dir, err := resolveSkillsDir(integrateScope, integratePath)
	if err != nil {
		return err
	}
	results, err := devpack.Status(dir)
	if err != nil {
		return err
	}
	fmt.Printf("Skills (%s):\n", dir)
	printSkillStatuses(results)

	bin, err := os.Executable()
	if err == nil {
		fmt.Printf("\nCLI binary: %s\n", bin)
	}
	return nil
}

func runIntegrateRemove(cmd *cobra.Command, args []string) error {
	if integrateSkillsOnly && integrateMCPOnly {
		return fmt.Errorf("--skills-only and --mcp-only are mutually exclusive")
	}

	dir, err := resolveSkillsDir(integrateScope, integratePath)
	if err != nil {
		return err
	}
	defaultDir, err := resolveSkillsDir("user", "")
	if err != nil {
		return err
	}
	touchMCP := shouldTouchMCP(integrateSkillsOnly, integrateMCPOnly, dir, defaultDir)

	if integrateMCPOnly {
		fmt.Println("Skipping skill pack removal (--mcp-only).")
	} else {
		results, err := devpack.Remove(dir)
		if err != nil {
			return err
		}
		fmt.Printf("Skills (%s):\n", dir)
		printSkillStatuses(results)
	}

	if !touchMCP {
		if integrateSkillsOnly {
			fmt.Println("\nSkipping MCP unregistration (--skills-only).")
		} else {
			fmt.Printf("\nSkipping MCP unregistration: %s is not the default Claude Code skills location (%s), and the MCP registration is global — narrowing --path/--scope must not reach outside it.\n", dir, defaultDir)
			fmt.Println("Run with --mcp-only (or without --path/--scope) to unregister it too.")
		}
		return nil
	}

	if _, err := exec.LookPath("claude"); err != nil {
		fmt.Println("\nclaude CLI not found — remove the MCP server yourself with:")
		fmt.Println("  claude mcp remove watchtower")
		return nil
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

// shouldTouchMCP decides whether "integrate remove" should also unregister
// the global MCP server. Skill-pack removal is scoped by --path/--scope, but
// MCP registration is global, so by default we only touch it when the
// resolved skills directory is the real default location — an explicitly
// narrowed target (a scratch --path, a non-default --scope) must not
// silently reach outside itself. --skills-only/--mcp-only override the
// default explicitly, in either direction.
func shouldTouchMCP(skillsOnly, mcpOnly bool, resolvedDir, defaultDir string) bool {
	if skillsOnly {
		return false
	}
	if mcpOnly {
		return true
	}
	return resolvedDir == defaultDir
}

func printSkillStatuses(results []devpack.SkillStatus) {
	for _, r := range results {
		note := ""
		switch r.State {
		case devpack.StateDrifted:
			note = "  (you edited this — left alone)"
		case devpack.StateForeign:
			note = "  (not ours — left alone)"
		}
		fmt.Printf("  %-26s %s%s\n", r.Name, r.State, note)
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
		fmt.Println("\nclaude CLI not found. Register the MCP server yourself with:")
		fmt.Printf("  claude mcp add watchtower -- %s mcp\n", bin)
		return nil
	}
	out, err := exec.Command("claude", "mcp", "add", "watchtower", "--", bin, "mcp").CombinedOutput()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			// Most commonly: already registered. Report, do not fail — the
			// user's existing registration is theirs to keep.
			fmt.Printf("\nMCP registration reported: %s", out)
			fmt.Printf("If it is not registered, run:\n  claude mcp add watchtower -- %s mcp\n", bin)
			return nil
		}
		return fmt.Errorf("registering the MCP server: %w", err)
	}
	fmt.Printf("\nMCP server registered: %s mcp\n", bin)
	return nil
}
