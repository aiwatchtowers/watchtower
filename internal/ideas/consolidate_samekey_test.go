package ideas

import (
	"context"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedSameKeyStreams stores a Jira and a Linear stream row that both cite
// ABC-1 — two different issues sharing a key.
func seedSameKeyStreams(t *testing.T, d *db.DB) {
	t.Helper()
	jiraAcct := seedJiraAccount(t, d)
	linAcct := db.SeedLinearTestAccount(t, d)
	seedStreamDigestIdeas(t, d, "jira", jiraAcct, []streamTopic{{Title: "J", Summary: "s",
		Decisions: []streamCandidate{{Text: "jira decision", Author: "Ann", Ref: "ABC-1"}}}})
	seedStreamDigestIdeas(t, d, "linear", linAcct, []streamTopic{{Title: "L", Summary: "s",
		Decisions: []streamCandidate{{Text: "linear decision", Author: "Bob", Ref: "ABC-1"}}}})
}

func mentionSourcesOf(t *testing.T, d *db.DB, ideaID int64) []string {
	t.Helper()
	ms, err := d.ListIdeaMentions(ideaID)
	require.NoError(t, err)
	var out []string
	for _, m := range ms {
		out = append(out, m.Source+":"+m.Ref)
	}
	return out
}

// IDEA-02: a ref rendered under both a Jira and a Linear stream keeps both
// provenances — the model's source picks one of them when it names one, else
// both sightings are recorded; neither overwrites the other.
func TestConsolidate_SameKeyOnJiraAndLinearKeepsBothSources(t *testing.T) {
	for _, tc := range []struct {
		modelSource string
		want        []string
	}{
		{"linear", []string{"linear:ABC-1"}},
		{"jira", []string{"jira:ABC-1"}},
		{"slack", []string{"jira:ABC-1", "linear:ABC-1"}},
	} {
		d := newTestDB(t)
		seedWorkspace(t, d)
		seedSameKeyStreams(t, d)
		reply := `{"ops":[{"op":"new_decision","title":"D","essence":"e",
			"mentions":[{"source":"` + tc.modelSource + `","ref":"ABC-1","quote":"q","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]}]}`
		gen := &fakeGen{reply: func(string) (string, error) { return reply, nil }}
		_, _, err := New(d, testCfg(), gen, testLogger()).runConsolidate(context.Background())
		require.NoError(t, err)
		ideas, err := d.ListIdeas(db.IdeaFilter{})
		require.NoError(t, err)
		require.Len(t, ideas, 1, tc.modelSource)
		assert.ElementsMatch(t, tc.want, mentionSourcesOf(t, d, ideas[0].ID), tc.modelSource)
	}
}

// attach_mention resolves an ambiguous ref the same way.
func TestConsolidate_AttachSameKeyPicksTheNamedSource(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	seedSameKeyStreams(t, d)
	ideaID := seedIdeaRow(t, d, db.Idea{Kind: "decision", Title: "Existing", Essence: "e", Status: "active", Source: "mined"})
	reply := fmt.Sprintf(`{"ops":[{"op":"attach_mention","idea_id":%d,
		"mention":{"source":"linear","ref":"ABC-1","quote":"q","author":"Bob","said_at":"2026-08-01T00:00:00Z"}}]}`, ideaID)
	gen := &fakeGen{reply: func(string) (string, error) { return reply, nil }}
	_, _, err := New(d, testCfg(), gen, testLogger()).runConsolidate(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []string{"linear:ABC-1"}, mentionSourcesOf(t, d, ideaID))
}
