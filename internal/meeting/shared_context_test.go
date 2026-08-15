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

// TestGatherSharedContext_BareParticipantExcluded is the negative twin: a
// participants blob that was never namespaced (still bare "U456") can never
// match the namespaced attendee id, so the track silently drops out of the
// meeting prep context instead of erroring. This must fail if the match ever
// becomes namespace-tolerant by accident.
func TestGatherSharedContext_BareParticipantExcluded(t *testing.T) {
	d := openTestDB(t)
	_, err := d.UpsertTrack(db.Track{
		Text:         "Ship the migration",
		Participants: `[{"name":"Bob","user_id":"U456","stance":"support"}]`,
	})
	require.NoError(t, err)

	p := New(d, &config.Config{}, &mockGenerator{}, nil)
	got := p.gatherSharedContext([]attendeeEntry{{SlackUserID: "1:U456"}})

	assert.NotContains(t, got, "Ship the migration")
}
