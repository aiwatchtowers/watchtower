package cmd

import (
	"fmt"

	"github.com/spf13/cobra"

	"watchtower/docs/guide"
	"watchtower/internal/hub"
)

var (
	Version   = "0.27.0"
	Commit    = "unknown"
	BuildDate = "unknown"
	// BuildFlavor names the build profile the artifact was produced with
	// (empty for the default build). Set via -ldflags by scripts/build-app.sh
	// and the Makefile build/install targets.
	BuildFlavor = ""
)

// The guide's links follow the release tag of a clean version, and the hub's
// heartbeat names the build flavor (ldflags set both before any init runs).
func init() {
	guide.Version = Version
	hub.BuildFlavor = BuildFlavor
}

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Print version information",
	RunE: func(cmd *cobra.Command, args []string) error {
		flavor := ""
		if BuildFlavor != "" {
			flavor = fmt.Sprintf(", flavor: %s", BuildFlavor)
		}
		fmt.Fprintf(cmd.OutOrStdout(), "watchtower %s (commit: %s, built: %s%s)\n", Version, Commit, BuildDate, flavor)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(versionCmd)
}
