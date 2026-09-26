package meeting

import (
	"testing"

	"watchtower/internal/config"
	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestGatherSharedContext_NamespacedParticipantIncluded pins
// gatherSharedContext's track-participant match: tracks.participants is a
// JSON blob backfilled to the "1:<rawID>" shape by migration 00054, matched
// against an attendee's SlackUserID — a scalar column that is always
// namespaced — via a plain substring check on the raw JSON text.
func TestGatherSharedContext_NamespacedParticipantIncluded(t *testing.T) {
	d := openTestDB(t)
	_, err := d.UpsertTrack(db.Track{
		Text:         "Ship the migration",
		Participants: `[{"name":"Bob","user_id":"1:U456","stance":"support"}]`,
	})
	require.NoError(t, err)

	p := New(d, &config.Config{}, &mockGenerator{}, nil)
	got := p.gatherSharedContext([]attendeeEntry{{SlackUserID: "1:U456"}})

	assert.Contains(t, got, "Ship the migration")
}

// TestGatherSharedContext_BareParticipantStillMatches: tracks.participants is
// stored verbatim from AI-authored JSON — the extraction prompt schema
// instructs raw ids — so every track written after migration 00054 goes right
// back to a bare participant id, regardless of the profile blob's own
// namespacing. gatherSharedContext matches the raw form of the attendee id
// (SplitAccountID), so a bare-stored participant still matches a namespaced
// attendee. This must fail if the match ever regresses to comparing the
// namespaced form directly.
func TestGatherSharedContext_BareParticipantStillMatches(t *testing.T) {
	d := openTestDB(t)
	_, err := d.UpsertTrack(db.Track{
		Text:         "Ship the migration",
		Participants: `[{"name":"Bob","user_id":"U456","stance":"support"}]`,
	})
	require.NoError(t, err)

	p := New(d, &config.Config{}, &mockGenerator{}, nil)
	got := p.gatherSharedContext([]attendeeEntry{{SlackUserID: "1:U456"}})

	assert.Contains(t, got, "Ship the migration")
}
