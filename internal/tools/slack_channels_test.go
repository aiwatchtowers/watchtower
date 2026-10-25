package tools

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestListSlackChannels_SortedAndFiltered(t *testing.T) {
	d := openDB(t)
	_, err := d.Exec(`INSERT INTO channels (id, name, type, is_member, num_members, is_archived) VALUES
		('1:C1', 'general', 'public', 1, 40, 0),
		('1:C2', 'Acme-Support', 'private', 0, 5, 0),
		('2:C3', 'old-acme', 'public', 0, 9, 1),
		('2:C4', 'quiet', 'public', 1, 2, 0)`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO messages (channel_id, ts, text) VALUES
		('1:C1', '1700000000.000100', 'a'), ('1:C1', '1700000500.000100', 'b'),
		('1:C2', '1700009000.000100', 'c'), ('2:C3', '1700001000.000100', 'd')`)
	require.NoError(t, err)

	tool := NewListSlackChannels()
	run := func(args string) []slackChannelRow {
		t.Helper()
		res, err := tool.Execute(context.Background(), d, Call{Args: json.RawMessage(args)})
		require.NoError(t, err)
		raw, err := json.Marshal(res)
		require.NoError(t, err)
		var out struct {
			Channels []slackChannelRow `json:"channels"`
		}
		require.NoError(t, json.Unmarshal(raw, &out))
		return out.Channels
	}

	all := run(`{}`)
	require.Len(t, all, 3, "the archived channel is hidden by default")
	assert.Equal(t, []string{"1:C2", "1:C1", "2:C4"}, []string{all[0].ID, all[1].ID, all[2].ID}, "newest activity first, silent last")
	assert.Equal(t, "1", all[0].Account)
	assert.Equal(t, "2023-11-15T00:43:20Z", all[0].LastActivity)
	assert.Equal(t, "", all[2].LastActivity)
	assert.True(t, all[1].IsMember)
	assert.Equal(t, 40, all[1].NumMembers)

	q := run(`{"query":"ACME"}`)
	require.Len(t, q, 1)
	assert.Equal(t, "1:C2", q[0].ID)

	withArchived := run(`{"query":"acme","include_archived":true}`)
	require.Len(t, withArchived, 2)
	assert.Equal(t, "2:C3", withArchived[1].ID)
	assert.True(t, withArchived[1].IsArchived)

	acct := run(`{"account":"2","include_archived":true}`)
	require.Len(t, acct, 2)
	assert.Equal(t, "2", acct[0].Account)
	assert.Empty(t, run(`{"query":"%"}`), "LIKE wildcards in the query are literal")
}

func TestListSlackChannels_NotOnAutomationSurface(t *testing.T) {
	tool := NewListSlackChannels()
	assert.Equal(t, AccessRead, tool.Access)
	assert.ElementsMatch(t, []string{"main", AutomationEditorSurface}, tool.Surfaces)
	assert.NotContains(t, tool.Surfaces, AutomationSurface)
}

func TestListSlackChannels_UnnamespacedIDHasNoAccount(t *testing.T) {
	d := openDB(t)
	_, err := d.Exec(`INSERT INTO channels (id, name, type, is_member, num_members, is_archived) VALUES
		('C9', 'legacy', 'public', 1, 3, 0), ('1:C1', 'general', 'public', 1, 4, 0)`)
	require.NoError(t, err)
	res, err := NewListSlackChannels().Execute(context.Background(), d, Call{Args: json.RawMessage(`{}`)})
	require.NoError(t, err)
	raw, err := json.Marshal(res)
	require.NoError(t, err)
	var out struct {
		Channels []slackChannelRow `json:"channels"`
	}
	require.NoError(t, json.Unmarshal(raw, &out))
	byID := map[string]string{}
	for _, c := range out.Channels {
		byID[c.ID] = c.Account
	}
	assert.Equal(t, "", byID["C9"], "no namespace, no account")
	assert.Equal(t, "1", byID["1:C1"])
}
