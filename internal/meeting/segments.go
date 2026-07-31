package meeting

import (
	"encoding/json"
	"fmt"
	"strings"
)

// TranscriptUtterance is one RoleAssigner merge unit of a transcript —
// consecutive same-speaker transcription segments merged into a single
// utterance with a time range. Persisted as a JSON array in
// meeting_transcripts.segments_json (snake_case keys, shared byte-for-byte
// with the Swift TranscriptUtterance model).
type TranscriptUtterance struct {
	Idx      int     `json:"idx"`
	StartSec float64 `json:"start_sec"`
	EndSec   float64 `json:"end_sec"`
	Speaker  string  `json:"speaker"`
	Text     string  `json:"text"`
	Deleted  bool    `json:"deleted"`
}

// ParseTranscriptSegments decodes and validates a segments_json payload.
// It rejects anything that is not a non-empty array of utterances with a
// speaker and text — a malformed file must degrade to a NULL column, never
// poison the row.
func ParseTranscriptSegments(data []byte) ([]TranscriptUtterance, error) {
	var utterances []TranscriptUtterance
	if err := json.Unmarshal(data, &utterances); err != nil {
		return nil, fmt.Errorf("decoding transcript segments: %w", err)
	}
	if len(utterances) == 0 {
		return nil, fmt.Errorf("transcript segments array is empty")
	}
	for i, u := range utterances {
		if u.Speaker == "" {
			return nil, fmt.Errorf("transcript segment %d has no speaker", i)
		}
		if u.Text == "" {
			return nil, fmt.Errorf("transcript segment %d has no text", i)
		}
	}
	return utterances, nil
}

// RenderTranscriptSegments is the canonical Go renderer for the load-bearing
// invariant transcript_text = render(segments where !deleted): one
// "[speaker] text" line per non-deleted utterance, newline-joined. It MUST
// stay behaviorally identical to the Swift side's TranscriptSegments.render
// (the UI-edit writer) — a deliberate dual-path like notes_md, pinned by
// matching fixtures in segments_test.go and TranscriptUtteranceTests.swift.
func RenderTranscriptSegments(utterances []TranscriptUtterance) string {
	var lines []string
	for _, u := range utterances {
		if u.Deleted {
			continue
		}
		lines = append(lines, fmt.Sprintf("[%s] %s", u.Speaker, u.Text))
	}
	return strings.Join(lines, "\n")
}
