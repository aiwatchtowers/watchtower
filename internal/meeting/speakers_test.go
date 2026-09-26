package meeting

import (
	"strings"
	"testing"
)

func TestParseSpeakerEmbeddingsValid(t *testing.T) {
	speakers, err := ParseSpeakerEmbeddings([]byte(
		`[{"speaker":"Я","embedding":[0.1,0.2]},{"speaker":"Speaker 1","embedding":[1,0]}]`))
	if err != nil {
		t.Fatalf("ParseSpeakerEmbeddings: %v", err)
	}
	if len(speakers) != 2 {
		t.Fatalf("expected 2 speakers, got %d", len(speakers))
	}
	if speakers[0].Speaker != "Я" || speakers[1].Speaker != "Speaker 1" {
		t.Fatalf("unexpected labels: %+v", speakers)
	}
	if len(speakers[0].Embedding) != 2 {
		t.Fatalf("embedding not decoded: %+v", speakers[0])
	}
}

func TestParseSpeakerEmbeddingsMalformedJSON(t *testing.T) {
	if _, err := ParseSpeakerEmbeddings([]byte(`{not json`)); err == nil {
		t.Fatal("expected decode error")
	}
}

func TestParseSpeakerEmbeddingsEmptyArray(t *testing.T) {
	if _, err := ParseSpeakerEmbeddings([]byte(`[]`)); err == nil || !strings.Contains(err.Error(), "empty") {
		t.Fatalf("expected empty-array error, got %v", err)
	}
}

func TestParseSpeakerEmbeddingsMissingLabel(t *testing.T) {
	if _, err := ParseSpeakerEmbeddings([]byte(`[{"speaker":"","embedding":[1]}]`)); err == nil || !strings.Contains(err.Error(), "no speaker label") {
		t.Fatalf("expected missing-label error, got %v", err)
	}
}

func TestParseSpeakerEmbeddingsEmptyEmbedding(t *testing.T) {
	if _, err := ParseSpeakerEmbeddings([]byte(`[{"speaker":"Speaker 1","embedding":[]}]`)); err == nil || !strings.Contains(err.Error(), "empty embedding") {
		t.Fatalf("expected empty-embedding error, got %v", err)
	}
}
