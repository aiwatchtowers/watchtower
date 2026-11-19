package cmd

import (
	"path/filepath"
	"testing"

	"github.com/spf13/cobra"
)

// TestAI_DesktopArgvParses runs the exact argument lists the Desktop's
// onboarding sends (WatchtowerAIService.testResult / .which) through the
// real root command. v0.28.0 shipped `ai test --json` while `ai test` had
// no such flag: cobra refused it before RunE and every agent showed
// "Check failed". RunE is swapped, so nothing runs a model.
func TestAI_DesktopArgvParses(t *testing.T) {
	origFlagConfig := flagConfig
	flagConfig = filepath.Join(t.TempDir(), "does-not-exist.yaml")
	t.Cleanup(func() { flagConfig = origFlagConfig })

	cases := []struct {
		name string
		cmd  *cobra.Command
		args []string
	}{
		{"ai test", aiTestCmd, []string{"ai", "test", "--json"}},
		{"ai test provider", aiTestCmd, []string{"ai", "test", "--json", "--provider", "claude"}},
		{"ai test provider cli-path", aiTestCmd, []string{"ai", "test", "--json", "--provider", "codex", "--cli-path", "/opt/homebrew/bin/codex"}},
		{"ai which", aiWhichCmd, []string{"ai", "which", "--provider", "claude", "--json"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			origRunE := tc.cmd.RunE
			called := false
			tc.cmd.RunE = func(*cobra.Command, []string) error { called = true; return nil }
			t.Cleanup(func() {
				tc.cmd.RunE = origRunE
				flagProvider, aiTestCLIPath, aiTestFlagJSON, aiWhichFlagJSON = "", "", false, false
				rootCmd.SetArgs(nil)
			})
			rootCmd.SetArgs(tc.args)
			if err := rootCmd.Execute(); err != nil {
				t.Fatalf("%v: %v", tc.args, err)
			}
			if !called {
				t.Fatalf("%v: RunE not reached", tc.args)
			}
		})
	}
}
