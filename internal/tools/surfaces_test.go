package tools_test

import (
	"os"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/tools"
)

// The chat surface list is a Go↔Swift dual path: Swift's
// AssistantToolSurface.chatSurfaces reads the same fixture.
func TestChatSurfaces_MatchSharedFixture(t *testing.T) {
	raw, err := os.ReadFile("testdata/chat_surfaces.txt")
	require.NoError(t, err)
	lines := strings.Split(strings.TrimSuffix(string(raw), "\n"), "\n")
	assert.Equal(t, lines, tools.ChatSurfaces())
}

func TestKnownChatSurface(t *testing.T) {
	for _, s := range []string{"main", "target", "automation_editor", "tuning"} {
		assert.True(t, tools.KnownChatSurface(s), s)
	}
	for _, s := range []string{"automation", "inbox", "project", "nope", ""} {
		assert.False(t, tools.KnownChatSurface(s), s)
	}
}
