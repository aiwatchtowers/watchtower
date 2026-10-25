package cmd

import (
	"errors"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
)

func auditEnv(vals map[string]string) func(string) string {
	return func(k string) string { return vals[k] }
}

func TestCLIAudit_OnlyUnderMarker(t *testing.T) {
	_, ok := cliAuditEvent("kb search", auditEnv(nil), nil)
	assert.False(t, ok, "the owner's own CLI writes no line")

	e, ok := cliAuditEvent("kb search", auditEnv(map[string]string{terminalSessionEnv: "42"}), nil)
	require.True(t, ok)
	assert.Equal(t, "terminal:42", e.Session)
	assert.Equal(t, "cli:kb search", e.Proc)
	assert.Equal(t, "cli", e.Surface)
	assert.Equal(t, "kb search", e.Tool)
	assert.Equal(t, "ok", e.Result)
	assert.Zero(t, e.Rows)
	assert.Zero(t, e.Bytes)
	assert.Empty(t, e.Filters)

	e, ok = cliAuditEvent("digest", auditEnv(map[string]string{automations.RunEnvMarker: "9"}), nil)
	require.True(t, ok)
	assert.Equal(t, "run:9", e.Session)
}

func TestCLIAudit_OnlyContentCommands(t *testing.T) {
	env := auditEnv(map[string]string{terminalSessionEnv: "42"})
	for _, path := range []string{"config set", "gmail status", "workbench board", ""} {
		_, ok := cliAuditEvent(path, env, nil)
		assert.False(t, ok, path)
	}
}

func TestCLIAudit_ErrorResult(t *testing.T) {
	e, ok := cliAuditEvent("memory recall", auditEnv(map[string]string{terminalSessionEnv: "42"}), errors.New("boom"))
	require.True(t, ok)
	assert.Equal(t, "error", e.Result)
}

func TestCLIAudit_ListedPathsExist(t *testing.T) {
	for path := range cliContentCommands {
		args := strings.Fields(path)
		c, rest, err := rootCmd.Find(args)
		require.NoError(t, err, path)
		assert.Empty(t, rest, path)
		assert.Equal(t, path, strings.TrimSpace(strings.TrimPrefix(c.CommandPath(), rootCmd.Name())), path)
	}
}
