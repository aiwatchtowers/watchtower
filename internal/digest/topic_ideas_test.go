package digest

import (
	"io"
	"log"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestStoreDigest_EmptyIdeasAndDecisionsPersistAsEmptyArrays pins the shape
// digest_topics.ideas/decisions must have when a topic mined nothing: the
// literal "[]", never "null".
//
// The ideas registry's ListDigestTopicIdeasAfter selects topics with
// `ideas != '[]' OR decisions != '[]'`. json.Marshal of a nil slice yields
// "null", which passes that filter — so with a "null" every single digest
// topic ever written would be handed to the consolidator as new material,
// rendering to nothing, and (before the floor-only persist path existed)
// wedging the floor on the first one forever.
func TestStoreDigest_EmptyIdeasAndDecisionsPersistAsEmptyArrays(t *testing.T) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	defer d.Close()

	p := &Pipeline{db: d, logger: log.New(io.Discard, "", 0)}
	result := &DigestResult{
		Summary: "s",
		Topics: []Topic{{
			Title:   "Routine standup",
			Summary: "nothing worth mining",
			// Ideas, Decisions, ActionItems, Situations all left nil — the
			// ordinary case for a topic the model found nothing in.
		}},
	}
	require.NoError(t, p.storeDigest("C1", "channel", 100, 200, result, 5, nil, 1))

	var ideas, decisions string
	require.NoError(t, d.QueryRow(`SELECT ideas, decisions FROM digest_topics`).Scan(&ideas, &decisions))
	assert.Equal(t, "[]", ideas)
	assert.Equal(t, "[]", decisions)

	topics, err := d.ListDigestTopicIdeasAfter(0, 0)
	require.NoError(t, err)
	assert.Empty(t, topics, "a topic that mined nothing must not reach the ideas consolidator")
}

// TestStoreDigest_MinedIdeasAndDecisionsSurvive is the positive half: a topic
// that DID mine candidates still persists them and still reaches the
// consolidator.
func TestStoreDigest_MinedIdeasAndDecisionsSurvive(t *testing.T) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	defer d.Close()

	p := &Pipeline{db: d, logger: log.New(io.Discard, "", 0)}
	result := &DigestResult{
		Summary: "s",
		Topics: []Topic{{
			Title:     "Vendor switch",
			Summary:   "s",
			Ideas:     []IdeaCandidate{{Text: "try a new vendor", By: "Ann", MessageTS: "1.1"}},
			Decisions: []Decision{{Text: "launch Friday", By: "Bob", MessageTS: "2.2"}},
		}},
	}
	require.NoError(t, p.storeDigest("C1", "channel", 100, 200, result, 5, nil, 1))

	topics, err := d.ListDigestTopicIdeasAfter(0, 0)
	require.NoError(t, err)
	require.Len(t, topics, 1)
	assert.Contains(t, topics[0].Ideas, "try a new vendor")
	assert.Contains(t, topics[0].Decisions, "launch Friday")
}
