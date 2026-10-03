package ai

import (
	"context"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestBuildArgs_WithoutReadFolderIsUnchanged pins today's argv byte for byte:
// the read-folder option must not move a single flag of an ordinary run.
func TestBuildArgs_WithoutReadFolderIsUnchanged(t *testing.T) {
	c := NewClient("claude-sonnet-4-6", "", "")
	args, stdin, err := c.buildArgs("sys", "hello", "stream-json", "")
	require.NoError(t, err)
	assert.Empty(t, stdin)
	assert.Equal(t, []string{
		"-p", "hello",
		"--output-format", "stream-json",
		"--model", "claude-sonnet-4-6",
		"--allowedTools", "mcp__watchtower",
		"--tools", "ToolSearch",
		"--disallowedTools", "Edit,Write,NotebookEdit,TodoWrite,Task,TodoRead," +
			"Bash,BashOutput,KillShell,WebFetch,Read,Grep,Glob,LS," +
			"ExitPlanMode,SlashCommand,Skill," +
			"CronCreate,CronDelete,CronList,RemoteTrigger,ScheduleWakeup,PushNotification,Workflow,Monitor," +
			"EnterWorktree,ExitWorktree,ListAgents,SendMessage,TaskCreate,TaskGet,TaskList,TaskStop,TaskUpdate," +
			"ListMcpResourcesTool,ReadMcpResourceTool,ReadMcpResourceDirTool," +
			"Agent,AskUserQuestion,EnterPlanMode,PowerShell,SendUserMessage,SubagentHandback,StructuredOutput," +
			"Artifact,ArtifactCheck,ArtifactComments,ArtifactData,ConnectGitHub,DesignSync,ReportFindings," +
			"ShareOnboardingGuide,WaitForMcpServers,WebSearch",
		"--setting-sources", "project,local",
		"--strict-mcp-config",
		"--verbose",
		"--system-prompt", "sys",
	}, args)
}

// ReadOnlyFolderDisallowedTools is DisallowedTools with exactly the four
// file-read tools taken out — everything else stays hidden.
func TestReadOnlyFolderDisallowedTools_DropsOnlyTheReadTools(t *testing.T) {
	readOnly := strings.Split(ReadOnlyFolderDisallowedTools, ",")
	all := strings.Split(DisallowedTools, ",")
	for _, tool := range []string{"Read", "Grep", "Glob", "LS"} {
		assert.NotContains(t, readOnly, tool)
	}
	assert.ElementsMatch(t, append(slices.Clone(readOnly), "Read", "Grep", "Glob", "LS"), all)
}

func TestBuildArgs_ReadFolderUnhidesOnlyTheReadTools(t *testing.T) {
	c := NewClient("m", "", "")
	c.SetReadFolder("/work/acme")
	args, _, err := c.buildArgs("sys", "hello", "stream-json", "")
	require.NoError(t, err)

	disallowed := strings.Split(flagValue(t, args, "--disallowedTools"), ",")
	for _, tool := range []string{"Read", "Grep", "Glob", "LS"} {
		assert.NotContains(t, disallowed, tool)
	}
	for _, tool := range []string{"Edit", "Write", "NotebookEdit", "Bash", "WebFetch", "WebSearch", "Task"} {
		assert.Contains(t, disallowed, tool)
	}
	// The folder's own .claude settings (a workbench carries hooks that
	// write session state and run the drift check) never load in a read run.
	assertFlagValue(t, args, "--setting-sources", "")
	assertFlagValue(t, args, "--tools", "ToolSearch,Read,Grep,Glob,LS")
	assertFlagValue(t, args, "--allowedTools", "mcp__watchtower")
	assert.Contains(t, args, "--strict-mcp-config")
}

// The external servers' deny list still rides on the read-folder value.
func TestBuildArgs_ReadFolderKeepsExternalDenyList(t *testing.T) {
	c := NewClient("m", "/tmp/db.sqlite", "")
	c.SetReadFolder("/work/acme")
	c.SetExternalMCPServers([]ExternalMCPServer{{Name: "trello", Kind: "stdio", Command: "x", DenyTools: []string{"create_card"}}})
	args, _, err := c.buildArgs("sys", "hello", "stream-json", "")
	require.NoError(t, err)
	assertFlagValue(t, args, "--disallowedTools", ReadOnlyFolderDisallowedTools+",mcp__trello__create_card")
}

// The CLI runs in the folder for a read run, and in the TCC-neutral temp
// dir otherwise — both the streaming and the sync path.
func TestQuery_ReadFolderIsTheWorkingDirectory(t *testing.T) {
	folder, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	mockPath := writeMockClaude(t, `printf '{"type":"result","result":"%s"}\n' "$(pwd -P)"`)

	c := NewClient("m", "", "")
	c.claudeCmd = mockPath
	c.SetReadFolder(folder)
	got, _, err := c.QuerySync(context.Background(), "", "hi", "")
	require.NoError(t, err)
	assert.Equal(t, folder, got)

	streamMock := writeMockClaude(t, `printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$(pwd -P)"
printf '{"type":"result","subtype":"success","result":"","session_id":"s1"}\n'`)
	c.claudeCmd = streamMock
	textCh, errCh, sidCh := c.Query(context.Background(), "", "hi", "")
	var text strings.Builder
	for chunk := range textCh {
		text.WriteString(chunk.Text)
	}
	for err := range errCh {
		require.NoError(t, err)
	}
	for range sidCh {
	}
	assert.Equal(t, folder, text.String())

	plain := NewClient("m", "", "")
	plain.claudeCmd = mockPath
	got, _, err = plain.QuerySync(context.Background(), "", "hi", "")
	require.NoError(t, err)
	assert.NotEqual(t, folder, got, "without a read folder the CLI never runs in it")
}
