package codex

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestClient_BuildArgs_WithoutReadFolderIsUnchanged pins today's argv byte
// for byte: the read-folder option must not move a flag of an ordinary run.
func TestClient_BuildArgs_WithoutReadFolderIsUnchanged(t *testing.T) {
	c := NewClient("gpt-5.4", "", "codex")
	args, stdin := c.buildArgs("sys", "hello", "/tmp/wd")
	assert.Empty(t, stdin)
	assert.Equal(t, []string{
		"exec",
		"--model", "gpt-5.4",
		"--json",
		"--ephemeral",
		"--skip-git-repo-check",
		"-c", "approval_policy=never",
		"-c", "sandbox_mode=read-only",
		"-c", "features.shell_tool=false",
		"-c", "features.unified_exec=false",
		"-c", "features.view_image=false",
		"-c", "features.computer_use=false",
		"-c", "features.browser_use=false",
		"-c", "features.browser_use_external=false",
		"-c", "features.apps=false",
		"-c", "features.plugins=false",
		"--cd", "/tmp/wd",
		"-c", "developer_instructions=sys",
		"hello",
	}, args)
}

// configValues returns every `-c` value in args, in order.
func configValues(args []string) []string {
	var out []string
	for i := 0; i < len(args)-1; i++ {
		if args[i] == "-c" {
			out = append(out, args[i+1])
		}
	}
	return out
}

// A read-folder run works in the folder under the read-only sandbox, with
// the shell — codex's only way to read a file — on and every other local
// tool, web search included, off.
func TestClient_BuildArgs_ReadFolder(t *testing.T) {
	c := NewClient("gpt-5.4", "/data/wt.db", "codex")
	c.SetReadFolder("/work/acme")
	args, _ := c.buildArgs("sys", "hello", c.readFolder)

	cd := slices.Index(args, "--cd")
	require.GreaterOrEqual(t, cd, 0)
	assert.Equal(t, "/work/acme", args[cd+1])
	assert.Equal(t, 1, strings.Count(strings.Join(args, "\x00"), "--cd"), "one working root")

	sandbox := slices.Index(args, "--sandbox")
	require.GreaterOrEqual(t, sandbox, 0, "the read-only sandbox flag")
	assert.Equal(t, "read-only", args[sandbox+1])

	cfg := configValues(args)
	assert.Contains(t, cfg, "sandbox_mode=read-only")
	assert.Contains(t, cfg, "approval_policy=never")
	assert.Contains(t, cfg, "features.shell_tool=true")
	assert.NotContains(t, cfg, "features.shell_tool=false")
	assert.Contains(t, cfg, `web_search="disabled"`)
	for _, off := range []string{
		"features.unified_exec=false", "features.view_image=false", "features.computer_use=false",
		"features.browser_use=false", "features.browser_use_external=false", "features.apps=false",
		"features.plugins=false",
	} {
		assert.Contains(t, cfg, off)
	}
	// The read-only watchtower server is mounted by -c (the folder is the
	// working root, so the temp .codex/config.toml route is not available).
	assert.Contains(t, cfg, "mcp_servers.watchtower.command="+strconv.Quote(watchtowerBinary()))
	assert.Contains(t, cfg, `mcp_servers.watchtower.args=["mcp", "--db-path", "/data/wt.db"]`)
	assert.Equal(t, "hello", args[len(args)-1])
}

// No database path → no watchtower server, as on an ordinary run.
func TestClient_BuildArgs_ReadFolderWithoutDBMountsNoServer(t *testing.T) {
	c := NewClient("gpt-5.4", "", "codex")
	c.SetReadFolder("/work/acme")
	args, _ := c.buildArgs("sys", "hello", c.readFolder)
	for _, v := range configValues(args) {
		assert.False(t, strings.HasPrefix(v, "mcp_servers."), "unexpected %s", v)
	}
}

// The CLI runs in the folder, and no temp MCP dir is made for it.
func TestQuery_ReadFolderIsTheWorkingDirectory(t *testing.T) {
	folder, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	script := filepath.Join(t.TempDir(), "fake-codex")
	body := `#!/bin/sh
cd_arg=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--cd" ]; then cd_arg="$2"; fi
  shift
done
echo "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"$(pwd -P)|$cd_arg\"}}"
`
	require.NoError(t, os.WriteFile(script, []byte(body), 0o755))

	c := NewClient("gpt-5.4", "/data/wt.db", script)
	c.SetReadFolder(folder)
	out, _, err := c.QuerySync(context.Background(), "sys", "hi", "")
	require.NoError(t, err)
	assert.Equal(t, folder+"|"+folder, out)

	textCh, errCh, sidCh := c.Query(context.Background(), "sys", "hi", "")
	var text strings.Builder
	for chunk := range textCh {
		text.WriteString(chunk.Text)
	}
	for err := range errCh {
		require.NoError(t, err)
	}
	for range sidCh {
	}
	assert.Equal(t, folder+"|"+folder, text.String())
}
