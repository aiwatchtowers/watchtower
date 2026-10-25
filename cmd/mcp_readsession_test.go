package cmd

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestMCPProcessSessionKey(t *testing.T) {
	env := func(v string) func(string) string {
		return func(k string) string {
			if k == terminalSessionEnv {
				return v
			}
			return ""
		}
	}
	assert.Equal(t, "terminal:42", mcpProcessSessionKey(env("42"), 7))
	assert.Equal(t, "pid:7", mcpProcessSessionKey(env(""), 7))
	assert.Equal(t, "pid:7", mcpProcessSessionKey(env("  "), 7), "a blank id is no terminal session")
}
