package meeting

import (
	"encoding/json"
	"fmt"
)

// SpeakerEmbedding is one diarized cluster's voice embedding, keyed by the
// FINAL rendered speaker label of the transcript ("Я", "Speaker N", or a
// matched display name). Persisted as a JSON array in
// meeting_transcripts.speakers_json (snake_case keys, shared byte-for-byte
// with the Swift SpeakerEmbedding model). The embedding is the diarizer's
// L2-normalized 256-dim vector; the Desktop rename flow folds it into
// voice_prints when the user names the cluster.
type SpeakerEmbedding struct {
	Speaker   string    `json:"speaker"`
	Embedding []float64 `json:"embedding"`
}

// ParseSpeakerEmbeddings decodes and validates a speakers_json payload. It
// rejects anything that is not a non-empty array of entries with a speaker
// label and a non-empty embedding — a malformed file must degrade to a NULL
// column, never poison the row (the ParseTranscriptSegments contract).
func ParseSpeakerEmbeddings(data []byte) ([]SpeakerEmbedding, error) {
	var speakers []SpeakerEmbedding
	if err := json.Unmarshal(data, &speakers); err != nil {
		return nil, fmt.Errorf("decoding speaker embeddings: %w", err)
	}
	if len(speakers) == 0 {
		return nil, fmt.Errorf("speaker embeddings array is empty")
	}
	for i, s := range speakers {
		if s.Speaker == "" {
			return nil, fmt.Errorf("speaker embedding %d has no speaker label", i)
		}
		if len(s.Embedding) == 0 {
			return nil, fmt.Errorf("speaker embedding %d (%s) has an empty embedding", i, s.Speaker)
		}
	}
	return speakers, nil
}
