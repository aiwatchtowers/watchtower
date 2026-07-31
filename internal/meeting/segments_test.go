package meeting

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Shared cross-side fixture: the Swift TranscriptUtteranceTests use the same
// input and expect the same rendered string, pinning the Go↔Swift canonical
// renderer equivalence (the transcript_text = render(segments) dual-path).
var segmentsFixture = []TranscriptUtterance{
	{Idx: 0, StartSec: 0, EndSec: 4.2, Speaker: "Я", Text: "привет как дела"},
	{Idx: 1, StartSec: 4.2, EndSec: 7.5, Speaker: "Speaker 1", Text: "нормально"},
	{Idx: 2, StartSec: 8.1, EndSec: 12.9, Speaker: "Я", Text: "отлично"},
}

const segmentsFixtureRendered = "[Я] привет как дела\n[Speaker 1] нормально\n[Я] отлично"

func TestRenderTranscriptSegments(t *testing.T) {
	assert.Equal(t, segmentsFixtureRendered, RenderTranscriptSegments(segmentsFixture))
}

func TestRenderTranscriptSegmentsSkipsDeleted(t *testing.T) {
	utterances := make([]TranscriptUtterance, len(segmentsFixture))
	copy(utterances, segmentsFixture)
	utterances[1].Deleted = true
	assert.Equal(t, "[Я] привет как дела\n[Я] отлично", RenderTranscriptSegments(utterances))
}

func TestRenderTranscriptSegmentsAllDeletedIsEmpty(t *testing.T) {
	// Degenerate but valid: every utterance soft-deleted → empty text, no crash.
	utterances := make([]TranscriptUtterance, len(segmentsFixture))
	copy(utterances, segmentsFixture)
	for i := range utterances {
		utterances[i].Deleted = true
	}
	assert.Equal(t, "", RenderTranscriptSegments(utterances))
}

func TestParseTranscriptSegmentsRoundTrip(t *testing.T) {
	raw := `[
		{"idx":0,"start_sec":0,"end_sec":4.2,"speaker":"Я","text":"привет как дела","deleted":false},
		{"idx":1,"start_sec":4.2,"end_sec":7.5,"speaker":"Speaker 1","text":"нормально","deleted":false},
		{"idx":2,"start_sec":8.1,"end_sec":12.9,"speaker":"Я","text":"отлично","deleted":false}
	]`
	utterances, err := ParseTranscriptSegments([]byte(raw))
	require.NoError(t, err)
	assert.Equal(t, segmentsFixture, utterances)
}

func TestParseTranscriptSegmentsRejectsInvalid(t *testing.T) {
	cases := map[string]string{
		"not json":        `{{{`,
		"not an array":    `{"idx":0}`,
		"empty array":     `[]`,
		"missing speaker": `[{"idx":0,"start_sec":0,"end_sec":1,"text":"hi","deleted":false}]`,
		"missing text":    `[{"idx":0,"start_sec":0,"end_sec":1,"speaker":"Я","deleted":false}]`,
		"duplicate idx": `[
			{"idx":0,"start_sec":0,"end_sec":1,"speaker":"Я","text":"a","deleted":false},
			{"idx":0,"start_sec":1,"end_sec":2,"speaker":"Я","text":"b","deleted":false}
		]`,
		"idx not array position": `[
			{"idx":1,"start_sec":0,"end_sec":1,"speaker":"Я","text":"a","deleted":false},
			{"idx":0,"start_sec":1,"end_sec":2,"speaker":"Я","text":"b","deleted":false}
		]`,
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := ParseTranscriptSegments([]byte(raw))
			assert.Error(t, err)
		})
	}
}
