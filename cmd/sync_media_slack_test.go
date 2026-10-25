package cmd

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/issuekey"
	"watchtower/internal/media"
	watchtowerslack "watchtower/internal/slack"
	"watchtower/internal/sync"
)

func TestWireSlackMedia_OpenerPerAccountAndKeyHook(t *testing.T) {
	database := db.OpenTestDB(t)
	c1 := watchtowerslack.NewClientWithAPIURLUnlimited("xoxp-1", "http://127.0.0.1:0/")
	c2 := watchtowerslack.NewClientWithAPIURLUnlimited("xoxp-2", "http://127.0.0.1:0/")
	orchs := []*sync.Orchestrator{
		sync.NewOrchestrator(database, c1, &config.Config{}, 1),
		sync.NewOrchestrator(database, c2, &config.Config{}, 2),
	}

	p := &media.Pipeline{Openers: map[string]media.Opener{"chat": media.LocalOpener{}}}
	wireSlackMedia(p, orchs, nil)
	op, ok := p.Openers["slack"].(media.SlackOpener)
	require.True(t, ok)
	assert.Same(t, c1, op.Clients[1])
	assert.Same(t, c2, op.Clients[2])
	assert.Contains(t, p.Openers, "chat", "the other openers stay")
	assert.Empty(t, p.AfterDescribed, "no key hook with key detection off")

	wireSlackMedia(p, orchs, issuekey.NewKeyDetector(database))
	assert.Len(t, p.AfterDescribed, 1)
}
