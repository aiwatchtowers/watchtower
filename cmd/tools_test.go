package cmd

import (
	"bytes"
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// runToolsSubcommand executes one tools subcommand against the temp workspace
// from setupWatchTestEnv and returns its stdout.
func runToolsSubcommand(t *testing.T, run func(cmd *cobra.Command, args []string) error, cmd *cobra.Command, args []string) (string, error) {
	t.Helper()
	buf := new(bytes.Buffer)
	cmd.SetOut(buf)
	err := run(cmd, args)
	return buf.String(), err
}

func TestToolsList_ShowsRegisteredTools(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	out, err := runToolsSubcommand(t, runToolsList, toolsListCmd, nil)
	require.NoError(t, err)

	for _, want := range []string{"list_targets", "get_target", "list_digests", "get_today_briefing", "list_jira_issues"} {
		assert.Contains(t, out, want)
	}
	assert.Contains(t, out, "tools describe", "list output should point to describe for discoverability")
}

func TestToolsDescribe_ShowsArgumentsFromSchema(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	out, err := runToolsSubcommand(t, runToolsDescribe, toolsDescribeCmd, []string{"list_targets"})
	require.NoError(t, err)

	assert.Contains(t, out, "list_targets")
	assert.Contains(t, out, "status")
	assert.Contains(t, out, "limit")
	assert.Contains(t, out, "integer", "limit should be described with its schema type")
	assert.Contains(t, out, "Example:")
}

func TestToolsDescribe_UnknownToolListsAvailable(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	_, err := runToolsSubcommand(t, runToolsDescribe, toolsDescribeCmd, []string{"nope"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), `unknown tool "nope"`)
	assert.Contains(t, err.Error(), "list_targets", "error should list available tools")
}

func TestToolsCall_ListTargetsEmptyDB(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	out, err := runToolsSubcommand(t, runToolsCall, toolsCallCmd, []string{"list_targets"})
	require.NoError(t, err)
	assert.Equal(t, "[]", strings.TrimSpace(out), "empty DB should print a JSON array")
}

func TestToolsCall_CoercesTypedArgs(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	out, err := runToolsSubcommand(t, runToolsCall, toolsCallCmd,
		[]string{"list_targets", "status=todo", "limit=5"})
	require.NoError(t, err)
	assert.Equal(t, "[]", strings.TrimSpace(out))
}

func TestToolsCall_ToolErrorSurfacesNonZero(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	_, err := runToolsSubcommand(t, runToolsCall, toolsCallCmd,
		[]string{"list_targets", "status=bogus"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "invalid status", "tool-level validation error must surface")
}

func TestToolsCall_BadArgReporting(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	// Wrong type for a schema integer.
	_, err := runToolsSubcommand(t, runToolsCall, toolsCallCmd, []string{"list_targets", "limit=abc"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "must be an integer")

	// Unknown argument names the accepted ones.
	_, err = runToolsSubcommand(t, runToolsCall, toolsCallCmd, []string{"list_targets", "bogus=1"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), `takes no argument "bogus"`)
	assert.Contains(t, err.Error(), "status")

	// Not key=value at all.
	_, err = runToolsSubcommand(t, runToolsCall, toolsCallCmd, []string{"list_targets", "oops"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "key=value")
}

func TestToolsCall_JSONArgs(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	toolsCallJSON = `{"status":"todo","limit":3}`
	defer func() { toolsCallJSON = "" }()

	out, err := runToolsSubcommand(t, runToolsCall, toolsCallCmd, []string{"list_targets"})
	require.NoError(t, err)
	assert.Equal(t, "[]", strings.TrimSpace(out))
}

func TestToolsCall_JSONAndPairsMutuallyExclusive(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	toolsCallJSON = `{"status":"todo"}`
	defer func() { toolsCallJSON = "" }()

	_, err := runToolsSubcommand(t, runToolsCall, toolsCallCmd, []string{"list_targets", "limit=3"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "not both")
}

func TestToolsCommandRegistered(t *testing.T) {
	names := map[string]bool{}
	for _, c := range rootCmd.Commands() {
		names[c.Name()] = true
	}
	assert.True(t, names["tools"], "tools command should be registered on rootCmd")

	subs := map[string]bool{}
	for _, c := range toolsCmd.Commands() {
		subs[c.Name()] = true
	}
	for _, want := range []string{"list", "describe", "call"} {
		assert.True(t, subs[want], "tools %s subcommand should be registered", want)
	}
}
