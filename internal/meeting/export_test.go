package meeting

import (
	"encoding/json"
	"errors"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func exportFixture() TranscriptExport {
	return TranscriptExport{
		ID: 7, Title: "Weekly sync", EventID: "evt1", EventTitle: "Weekly sync (calendar)",
		CreatedAt: "2026-10-28T09:00:00Z", DurationSec: 3725,
		Text: "[Anna] Hello\n[Bob] Hi",
		Segments: []TranscriptUtterance{
			{Idx: 0, StartSec: 1.5, EndSec: 4, Speaker: "Anna", Text: "Hello"},
			{Idx: 1, StartSec: 5, EndSec: 6, Speaker: "Bob", Text: "dropped line", Deleted: true},
			{Idx: 2, StartSec: 3661.2346, EndSec: 3662.9999, Speaker: "Bob", Text: "Hi"},
			{Idx: 3, StartSec: 3700, EndSec: 3690, Speaker: "", Text: "no speaker"},
		},
	}
}

func TestRenderTranscriptExport(t *testing.T) {
	legacy := TranscriptExport{ID: 3, Title: "Old one", CreatedAt: "2026-01-02T03:04:05Z", Text: "[Anna] flat text\n[Bob] more"}

	cases := []struct {
		name   string
		in     TranscriptExport
		format string
		want   string
	}{
		{"txt segments", exportFixture(), "txt",
			"[00:00:01] Anna: Hello\n[01:01:01] Bob: Hi\n[01:01:40] no speaker\n"},
		{"txt legacy row keeps flat text", legacy, "txt", "[Anna] flat text\n[Bob] more\n"},
		{"md segments", exportFixture(), "md",
			"# Weekly sync\n\nDate: 2026-10-28 · Duration: 01:02:05 · Event: Weekly sync (calendar)\n\n" +
				"**Anna** · 00:00:01\nHello\n\n**Bob** · 01:01:01\nHi\n\n01:01:40\nno speaker\n"},
		{"md legacy row, no duration or event", legacy, "md",
			"# Old one\n\nDate: 2026-01-02\n\n[Anna] flat text\n[Bob] more\n"},
		{"srt cues number the kept utterances, end never before start", exportFixture(), "srt",
			"1\n00:00:01,500 --> 00:00:04,000\nAnna: Hello\n\n" +
				"2\n01:01:01,235 --> 01:01:03,000\nBob: Hi\n\n" +
				"3\n01:01:40,000 --> 01:01:40,000\nno speaker\n\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := RenderTranscriptExport(tc.in, tc.format)
			require.NoError(t, err)
			assert.Equal(t, tc.want, string(got))
		})
	}
}

func TestRenderTranscriptExport_SRTNeedsSegments(t *testing.T) {
	for name, segs := range map[string][]TranscriptUtterance{
		"no segments": nil,
		"all deleted": {{Idx: 0, StartSec: 1, EndSec: 2, Speaker: "A", Text: "x", Deleted: true}},
	} {
		_, err := RenderTranscriptExport(TranscriptExport{Title: "t", Text: "x", Segments: segs}, "srt")
		assert.True(t, errors.Is(err, ErrNoTimedSegments), name)
		assert.EqualError(t, err, "no timed segments", name)
	}
}

func TestRenderTranscriptExport_JSON(t *testing.T) {
	in := exportFixture()
	in.Private = true
	got, err := RenderTranscriptExport(in, "json")
	require.NoError(t, err)
	var out map[string]any
	require.NoError(t, json.Unmarshal(got, &out))
	keys := make([]string, 0, len(out))
	for k := range out {
		keys = append(keys, k)
	}
	assert.ElementsMatch(t, []string{"id", "title", "event_id", "created_at", "duration_sec", "private", "segments", "transcript_text"}, keys)
	assert.Equal(t, true, out["private"])
	assert.Equal(t, "evt1", out["event_id"])
	segs := out["segments"].([]any)
	require.Len(t, segs, 3, "the deleted utterance is never exported")
	assert.Equal(t, map[string]any{"start_sec": 1.5, "end_sec": 4.0, "speaker": "Anna", "text": "Hello"}, segs[0])

	legacy, err := RenderTranscriptExport(TranscriptExport{ID: 1, Title: "t", Text: "flat"}, "json")
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal(legacy, &out))
	assert.Equal(t, []any{}, out["segments"], "a row without segments exports an empty array, not null")
	assert.Equal(t, "flat", out["transcript_text"])
}

func TestRenderTranscriptExport_UnknownFormat(t *testing.T) {
	_, err := RenderTranscriptExport(exportFixture(), "docx")
	assert.ErrorContains(t, err, `unknown export format "docx"`)
}
