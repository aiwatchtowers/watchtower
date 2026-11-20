package sessionagent

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/sessionfeed"
)

// chatTranscript writes a Claude conversation with an owner line and an
// open Bash call.
func chatTranscript(t *testing.T) sessionfeed.Conversation {
	t.Helper()
	path := filepath.Join(t.TempDir(), "conv.jsonl")
	lines := `{"type":"user","uuid":"u1","timestamp":"2026-10-01T10:00:00Z","message":{"role":"user","content":"hello"}}` + "\n" +
		`{"type":"assistant","uuid":"a1","timestamp":"2026-10-01T10:00:05Z","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"go test ./..."}}]}}` + "\n"
	require.NoError(t, os.WriteFile(path, []byte(lines), 0o600))
	return sessionfeed.Conversation{AgentSessionID: "conv", Path: path}
}

func TestReadChatReadsEntriesLiveAndPaths(t *testing.T) {
	c := chatTranscript(t)
	read, err := readChat(context.Background(), []sessionfeed.Conversation{c}, nil, "", time.Now())
	require.NoError(t, err)
	assert.NotEmpty(t, read.Entries)
	require.NotNil(t, read.Live)
	require.NotNil(t, read.Live.Current)
	assert.Equal(t, "go test ./...", read.Live.Current.Summary)
	assert.NoError(t, read.LiveErr)
	assert.Contains(t, read.Paths, c.Path)
}

// A conversation file not written yet (a session just started) is no live
// error: no block, quiet. A file that exists but cannot be read is.
func TestReadChatMissingConversationIsNoLiveError(t *testing.T) {
	missing := sessionfeed.Conversation{AgentSessionID: "new", Path: filepath.Join(t.TempDir(), "new.jsonl")}
	read, err := readChat(context.Background(), []sessionfeed.Conversation{missing}, nil, "", time.Now())
	require.NoError(t, err)
	assert.Nil(t, read.Live)
	assert.NoError(t, read.LiveErr)

	notFile := sessionfeed.Conversation{AgentSessionID: "dir", Path: t.TempDir()}
	read, err = readChat(context.Background(), []sessionfeed.Conversation{notFile}, nil, "", time.Now())
	require.NoError(t, err)
	assert.Nil(t, read.Live)
	assert.Error(t, read.LiveErr, "a conversation that exists but cannot be read is a live error")
}

// A live snapshot that stalls is given up after liveReadTimeout: the pass
// still returns the fresh entries, with LiveErr.
func TestReadChatStalledLiveReturnsEntriesWithLiveErr(t *testing.T) {
	c := chatTranscript(t)
	synctest.Test(t, func(t *testing.T) {
		stall := make(chan struct{})
		defer close(stall)
		prev := liveOf
		liveOf = func(sessionfeed.Conversation, bool, time.Time) (*sessionfeed.Live, error) {
			<-stall
			return nil, nil
		}
		defer func() { liveOf = prev }()
		start := time.Now()
		read, err := readChat(context.Background(), []sessionfeed.Conversation{c}, nil, "", time.Now())
		require.NoError(t, err)
		assert.Equal(t, liveReadTimeout, time.Since(start))
		assert.NotEmpty(t, read.Entries)
		assert.Nil(t, read.Live)
		assert.ErrorIs(t, read.LiveErr, errLiveTimedOut)
	})
}
