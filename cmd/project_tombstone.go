package cmd

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/spf13/cobra"
)

// projectTombstoneCmd answers what a folder set up before the Workbench
// rename and never resynced still runs: its SessionStart hook `project brief
// --project N`, its Stop hook `project check --project N --stop-hook` and
// any other `project …` spelling (ask #312). It serves nothing — no config,
// no database, no board — and only says the setup is outdated. It always
// exits 0: a Stop hook exiting 2 would block the turn (PROJ-07). The brief
// (SessionStart, whose stdout the agent reads) prints the line on stdout;
// anything else prints it on stderr only, since a Stop hook's stdout may be
// parsed as JSON.
var projectTombstoneCmd = &cobra.Command{
	Use:                "project",
	Short:              "Removed: the pre-rename spelling of workbench",
	Hidden:             true,
	DisableFlagParsing: true,
	Args:               cobra.ArbitraryArgs,
	PersistentPreRunE:  func(*cobra.Command, []string) error { return nil },
	RunE: func(cmd *cobra.Command, args []string) error {
		line := preRenameSetupLine(preRenameWorkbenchID(args))
		if len(args) > 0 && args[0] == "brief" {
			fmt.Fprintln(cmd.OutOrStdout(), line)
			return nil
		}
		fmt.Fprintln(cmd.ErrOrStderr(), line)
		return nil
	},
}

// mcpFlagPreRename is the old registration's `mcp --project N`; runMCP
// refuses it with preRenameSetupLine instead of binding a session.
var mcpFlagPreRename string

func init() {
	rootCmd.AddCommand(projectTombstoneCmd)
	mcpCmd.Flags().StringVar(&mcpFlagPreRename, "project", "", "removed: the pre-rename spelling of --workbench")
	_ = mcpCmd.Flags().MarkHidden("project")
}

// preRenameSetupLine is the one line every pre-rename spelling answers with;
// id is the workbench id the old argv named, or "" when it named none.
func preRenameSetupLine(id string) string {
	line := "Watchtower: this folder was set up before the Workbench rename and its setup no longer runs — ask the owner to run Repair install in Watchtower"
	if id != "" {
		line += " (or 'watchtower workbench resync " + id + "')"
	}
	return line + "."
}

// preRenameWorkbenchID is the positive integer given to --project in args
// (`--project N` or `--project=N`), or "".
func preRenameWorkbenchID(args []string) string {
	for i, a := range args {
		var raw string
		switch {
		case a == "--project" && i+1 < len(args):
			raw = args[i+1]
		case strings.HasPrefix(a, "--project="):
			raw = strings.TrimPrefix(a, "--project=")
		default:
			continue
		}
		if id, err := strconv.ParseInt(raw, 10, 64); err == nil && id > 0 {
			return strconv.FormatInt(id, 10)
		}
		return ""
	}
	return ""
}
