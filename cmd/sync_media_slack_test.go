package cmd

import (
	"context"
	"io"
	"log"
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

	p := &media.Pipeline{DB: database, Openers: map[string]media.Opener{"chat": media.LocalOpener{}}}
	wireSlackMedia(p, orchs, nil, log.New(io.Discard, "", 0))
	op, ok := p.Openers["slack"].(media.SlackOpener)
	require.True(t, ok)
	assert.Same(t, c1, op.Clients[1])
	assert.Same(t, c2, op.Clients[2])
	assert.Contains(t, p.Openers, "chat", "the other openers stay")
	assert.Empty(t, p.AfterDescribed, "no key hook with key detection off")

	wireSlackMedia(p, orchs, issuekey.NewKeyDetector(database), log.New(io.Discard, "", 0))
	assert.Len(t, p.AfterDescribed, 1)
}

// The team domain is seeded from slack_accounts at wiring: a
// <team>.slack.com file URL is accepted before any ensureWorkspace ran.
func TestWireSlackMedia_SeedsTeamDomain(t *testing.T) {
	database := db.OpenTestDB(t)
	acme, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T1", TeamName: "Acme", TeamDomain: "acme", Label: "Work"})
	require.NoError(t, err)
	bare, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T2", TeamName: "Beta", Label: "Other"})
	require.NoError(t, err)
	c1 := watchtowerslack.NewClientWithAPIURLUnlimited("xoxp-1", "http://127.0.0.1:0/")
	c2 := watchtowerslack.NewClientWithAPIURLUnlimited("xoxp-2", "http://127.0.0.1:0/")
	orchs := []*sync.Orchestrator{
		sync.NewOrchestrator(database, c1, &config.Config{}, acme),
		sync.NewOrchestrator(database, c2, &config.Config{}, bare),
	}
	wireSlackMedia(&media.Pipeline{DB: database, Openers: map[string]media.Opener{}}, orchs, nil, log.New(io.Discard, "", 0))

	// A cancelled context: the accepted URL fails on the context, never on
	// the network, and a refused one before any request.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, _, err = c1.DownloadFile(ctx, "https://acme.slack.com/files-pri/T1-F1/chart.png", 100)
	require.Error(t, err)
	assert.NotErrorIs(t, err, watchtowerslack.ErrFileURLRefused, "the seeded team host is accepted")
	_, _, err = c2.DownloadFile(ctx, "https://acme.slack.com/files-pri/T1-F1/chart.png", 100)
	assert.ErrorIs(t, err, watchtowerslack.ErrFileURLRefused, "an account without a domain accepts no team host")
}
