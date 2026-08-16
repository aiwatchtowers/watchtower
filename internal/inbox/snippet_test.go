package inbox

import (
	"testing"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestEnrichSnippetWithoutDB(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "user mention with display name",
			in:   "hello <@U010T16N5LN|Maksym Yukhno> how are you",
			want: "hello @Maksym Yukhno how are you",
		},
		{
			name: "user mention without display name",
			in:   "hello <@U010T16N5LN> how are you",
			want: "hello @U010T16N5LN how are you",
		},
		{
			name: "channel reference",
			in:   "check <#C01234567|general> for updates",
			want: "check #general for updates",
		},
		{
			name: "link with display text",
			in:   "see <https://example.com|this link>",
			want: "see this link",
		},
		{
			name: "bare url",
			in:   "visit <https://example.com/foo>",
			want: "visit https://example.com/foo",
		},
		{
			name: "special mention here",
			in:   "<!here|here> please review",
			want: "@here please review",
		},
		{
			name: "special mention channel",
			in:   "<!channel> important",
			want: "@channel important",
		},
		{
			name: "subteam mention",
			in:   "cc <!subteam^S01234|@backend-team>",
			want: "cc @backend-team",
		},
		{
			name: "emoji stripped",
			in:   "great job :thumbsup: :tada:",
			want: "great job",
		},
		{
			name: "code block stripped",
			in:   "before ```some code``` after",
			want: "before after",
		},
		{
			name: "html entities",
			in:   "foo &amp; bar &lt;tag&gt;",
			want: "foo & bar <tag>",
		},
		{
			name: "multiple user mentions with names",
			in:   "<@U111|Alice> and <@U222|Bob> discussed",
			want: "@Alice and @Bob discussed",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := enrichSnippet(tt.in, nil)
			if got != tt.want {
				t.Errorf("enrichSnippet(%q, nil)\n  got:  %q\n  want: %q", tt.in, got, tt.want)
			}
		})
	}
}

func TestEnrichSnippetResolvesRawMentionViaDB(t *testing.T) {
	d := newTestDB(t)
	require.NoError(t, d.UpsertUser(db.User{ID: "U3", Name: "bob", DisplayName: "Bob Brown"}))

	assert.Equal(t, "ping @Bob Brown please", enrichSnippet("ping <@U3> please", d))
	assert.Equal(t, "ping @U404NOPE please", enrichSnippet("ping <@U404NOPE> please", d),
		"unknown raw mention keeps the raw id; the addressee must never be dropped")
}

// TestEnrichSnippetResolvesNamespacedMentionViaDB covers the mixed-form case
// introduced by migration 00048: message text keeps the raw id forever
// ("<@U1>"), while users.id may be namespaced ("1:U1").
func TestEnrichSnippetResolvesNamespacedMentionViaDB(t *testing.T) {
	d := newTestDB(t)
	require.NoError(t, d.UpsertUser(db.User{ID: "1:U1", Name: "alice", DisplayName: "Alice A"}))

	assert.Equal(t, "hey @Alice A", enrichSnippet("hey <@U1>", d),
		"a raw id parsed from message text must resolve against a namespaced users.id")
}

// TestEnrichSnippetPipeFormNeverQueriesDB confirms the "<@U1|Name>" form
// always short-circuits to the markup's own name, without a DB lookup — the
// DB is seeded with a conflicting name for the same raw id to prove the
// markup name wins rather than being overridden by a lookup.
func TestEnrichSnippetPipeFormNeverQueriesDB(t *testing.T) {
	d := newTestDB(t)
	require.NoError(t, d.UpsertUser(db.User{ID: "1:U1", Name: "alice", DisplayName: "DB Name"}))

	assert.Equal(t, "hey @Explicit Name", enrichSnippet("hey <@U1|Explicit Name>", d))
}
