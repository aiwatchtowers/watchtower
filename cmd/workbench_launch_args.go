package cmd

import (
	"errors"
	"fmt"

	"github.com/spf13/cobra"

	"watchtower/internal/agentkind"
	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/devpack"
)

// codexFindBinary looks codex up when config has no codex_path. A seam so no
// test depends on a codex install. codex.FindBinary answers a bare "codex"
// on a miss, which CodexLaunchArgs reads as not found.
var codexFindBinary = func() (string, error) { return codex.FindBinary(""), nil }

var workbenchLaunchArgsCmd = &cobra.Command{
	Use:   "launch-args --agent codex --workbench N --json",
	Short: "Print how to launch an agent in a workbench terminal (codex only)",
	Long: "Prints one JSON object {\"binary\", \"path_prepend\", \"args\"}: the codex binary (codex_path from\n" +
		"config, else the nvm-aware lookup), its directory to put in front of PATH, and the launch flags\n" +
		"(--no-daemon, the workbench MCP server, the workbench hooks). The caller appends\n" +
		"`[resume <id>] -- <prompt>`; the `--` is needed, codex refuses a prompt that starts with '-'.\n" +
		"No codex binary: exit 3 and {\"error\":\"codex_not_found\"}. A bad invocation (missing --json,\n" +
		"no --workbench, an unknown agent, or --agent claude, whose argv the Desktop builds itself)\n" +
		"exits 2 with a message on stderr.",
	// Opens no database: only config's codex_path is read.
	PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
	Args:              cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		if err := checkLaunchArgsFlags(); err != nil {
			return err
		}
		cfg, err := config.Load(flagConfig)
		if err != nil {
			return err
		}
		bin, err := workbenchExecutable()
		if err != nil {
			return fmt.Errorf("determining the watchtower binary path: %w", err)
		}
		la, err := devpack.CodexLaunchArgs(cfg, bin, launchArgsFlagWorkbench, codexFindBinary)
		if errors.Is(err, devpack.ErrCodexNotFound) {
			if werr := writeJSON(cmd.OutOrStdout(), map[string]string{"error": "codex_not_found"}); werr != nil {
				return werr
			}
			return &exitCodeError{code: 3, err: err}
		}
		if err != nil {
			return err
		}
		return writeJSON(cmd.OutOrStdout(), la)
	},
}

var (
	launchArgsFlagAgent     string
	launchArgsFlagWorkbench int64
	launchArgsFlagJSON      bool
)

func init() {
	c := workbenchLaunchArgsCmd
	c.Flags().StringVar(&launchArgsFlagAgent, "agent", "", "agent kind: codex")
	c.Flags().Int64Var(&launchArgsFlagWorkbench, "workbench", 0, "workbench id")
	c.Flags().BoolVar(&launchArgsFlagJSON, "json", false, "print JSON (the only output format)")
	workbenchCmd.AddCommand(c)
}

func checkLaunchArgsFlags() error {
	if !launchArgsFlagJSON {
		return usageError("launch-args prints JSON only: pass --json")
	}
	if launchArgsFlagWorkbench <= 0 {
		return usageError("--workbench N is required")
	}
	kind, ok := agentkind.Parse(launchArgsFlagAgent)
	if !ok {
		return usageError("unknown --agent %q (want codex)", launchArgsFlagAgent)
	}
	if kind != agentkind.Codex {
		return usageError("launch-args supports --agent codex only; the Desktop builds the %s argv itself", kind.DisplayName())
	}
	return nil
}
