package cmd

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"testing"

	"github.com/slack-go/slack"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations/builtin"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/reactioncmd"
)

// pollLister is the owner's reactions.list for a manual poll.
type pollLister struct{ items []slack.ReactedItem }

func (l *pollLister) ListUserReactions(context.Context, string) ([]slack.ReactedItem, error) {
	return l.items, nil
}

// newPollCLI is the C3 CLI fixture with one Slack account (owner U001)
// whose reactions.list returns the owner's ✅ on one message, and the
// compose reply for it.
func newPollCLI(t *testing.T) *c3CLI {
	t.Helper()
	c := newC3CLI(t, `{"text":"Handle the deploy","reason":"owner flagged it"}`)
	require.NoError(t, c.d.MarkReactionCommandsSeeded(1))
	m := &slack.Message{}
	m.Timestamp, m.User, m.Text = "111.1", "U002", "please handle the deploy"
	lister := &pollLister{items: []slack.ReactedItem{{
		Item:      slack.Item{Type: "message", Channel: "C1", Message: m},
		Reactions: []slack.ItemReaction{{Name: "white_check_mark", Users: []string{"U001"}}},
	}}}
	orig := reactionCommandsAccounts
	reactionCommandsAccounts = func(*db.DB, *config.Config, *log.Logger) func(context.Context) ([]reactioncmd.Account, error) {
		return func(context.Context) ([]reactioncmd.Account, error) {
			return []reactioncmd.Account{{AccountID: 1, OwnerID: "U001", Lister: lister}}, nil
		}
	}
	t.Cleanup(func() { reactionCommandsAccounts = orig })
	return c
}

func (c *c3CLI) reactionLedger(t *testing.T) []string {
	t.Helper()
	rows, err := c.d.Query(`SELECT status FROM reaction_commands ORDER BY id`)
	require.NoError(t, err)
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		require.NoError(t, rows.Scan(&s))
		out = append(out, s)
	}
	require.NoError(t, rows.Err())
	return out
}

func TestReactionCommandsPoll_UsesRecipe(t *testing.T) {
	c := newPollCLI(t)
	c.moved(t, reactionsID)
	code, stdout, stderr := runCLI(t, "reaction-commands", "poll")
	require.Equal(t, 0, code, stderr)
	assert.Contains(t, stdout, "dispatched 1 reaction command(s)")
	a := c.builtinRow(t, reactionsID)
	runs := c.runs(t, a.ID)
	require.Len(t, runs, 1, "the command was composed by one run of the Reactions recipe")
	assert.Equal(t, db.TriggerSync, runs[0].Trigger)
	assert.Equal(t, db.RunSucceeded, runs[0].Status, runs[0].Error)
	assert.Equal(t, []string{"dispatched"}, c.reactionLedger(t))
	assert.Equal(t, 1, c.gen.CallCount())
}

// An edited Reactions copy not confirmed yet: the poll says so and claims
// nothing, so the reaction dispatches once the owner confirms.
func TestReactionCommandsPoll_UnconfirmedCopyClaimsNothing(t *testing.T) {
	c := newPollCLI(t)
	c.moved(t, reactionsID)
	e, ok := builtin.Lookup(reactionsID)
	require.True(t, ok)
	prompt, err := e.DefaultPrompt("compose", "")
	require.NoError(t, err)
	data, err := builtin.RenderOwnerCopy(e, map[string]string{"compose": prompt + "\nKeep it short."})
	require.NoError(t, err)
	path := builtin.OwnerCopyPath(c.ws, reactionsID)
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o700))
	require.NoError(t, os.WriteFile(path, data, 0o600))

	code, stdout, stderr := runCLI(t, "reaction-commands", "poll")
	require.Equal(t, 0, code, stderr)
	assert.Contains(t, stdout, "Reactions: your edited copy is not confirmed yet")
	assert.Contains(t, stdout, "dispatched 0 reaction command(s)")
	assert.Empty(t, c.reactionLedger(t))
	assert.Empty(t, c.runs(t, c.builtinRow(t, reactionsID).ID))
	assert.Zero(t, c.gen.CallCount())
}

// Before the Reactions built-in moved, the poll composes in Go as before:
// no automation run.
func TestReactionCommandsPoll_LegacyBeforeTheMove(t *testing.T) {
	c := newPollCLI(t)
	code, stdout, stderr := runCLI(t, "reaction-commands", "poll")
	require.Equal(t, 0, code, stderr)
	assert.Contains(t, stdout, "dispatched 1 reaction command(s)")
	assert.Equal(t, []string{"dispatched"}, c.reactionLedger(t))
	assert.Empty(t, c.runs(t, c.builtinRow(t, reactionsID).ID))
}
