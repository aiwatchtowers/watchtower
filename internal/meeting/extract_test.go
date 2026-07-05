package meeting

import (
	"context"
	"testing"

	"watchtower/internal/config"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func newExtractPipeline(resp string, errs ...error) *Pipeline {
	var e error
	if len(errs) > 0 {
		e = errs[0]
	}
	return &Pipeline{
		generator: &mockGenerator{response: resp, err: e},
		cfg:       &config.Config{Digest: config.DigestConfig{Language: "English"}},
	}
}

func TestExtractDiscussionTopics_EmptyText(t *testing.T) {
	p := newExtractPipeline("")
	res, err := p.ExtractDiscussionTopics(context.Background(), "", "Daily Standup")
	require.NoError(t, err)
	require.NotNil(t, res)
	assert.Empty(t, res.Topics)
}

func TestExtractDiscussionTopics_WhitespaceOnly(t *testing.T) {
	p := newExtractPipeline("")
	res, err := p.ExtractDiscussionTopics(context.Background(), "   \n\t  ", "")
	require.NoError(t, err)
	assert.Empty(t, res.Topics)
}

func TestExtractDiscussionTopics_HappyPath(t *testing.T) {
	resp := `{
		"topics": [
			{"text": "  Roadmap review  ", "priority": "HIGH"},
			{"text": "Hiring update", "priority": "low"},
			{"text": "Random thoughts", "priority": "INVALID"}
		],
		"notes": "merged duplicates"
	}`
	p := newExtractPipeline(resp)

	res, err := p.ExtractDiscussionTopics(context.Background(), "raw text", "Weekly")
	require.NoError(t, err)
	require.Len(t, res.Topics, 3)

	assert.Equal(t, "Roadmap review", res.Topics[0].Text, "text trimmed")
	assert.Equal(t, "high", res.Topics[0].Priority, "priority normalized to lowercase")

	assert.Equal(t, "low", res.Topics[1].Priority)

	// Invalid priority is reset to empty.
	assert.Equal(t, "", res.Topics[2].Priority)
	assert.Equal(t, "merged duplicates", res.Notes)
}

func TestExtractDiscussionTopics_DropsEmptyTopics(t *testing.T) {
	resp := `{"topics":[{"text":"","priority":"high"},{"text":"   ","priority":"low"},{"text":"Real topic"}]}`
	p := newExtractPipeline(resp)
	res, err := p.ExtractDiscussionTopics(context.Background(), "raw", "")
	require.NoError(t, err)
	require.Len(t, res.Topics, 1)
	assert.Equal(t, "Real topic", res.Topics[0].Text)
}

func TestExtractDiscussionTopics_StripsMarkdownFences(t *testing.T) {
	resp := "```json\n" + `{"topics":[{"text":"X"}]}` + "\n```"
	p := newExtractPipeline(resp)
	res, err := p.ExtractDiscussionTopics(context.Background(), "raw", "")
	require.NoError(t, err)
	require.Len(t, res.Topics, 1)
	assert.Equal(t, "X", res.Topics[0].Text)
}

func TestExtractDiscussionTopics_MalformedJSON(t *testing.T) {
	p := newExtractPipeline(`not json`)
	_, err := p.ExtractDiscussionTopics(context.Background(), "raw", "")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "parsing AI response")
}

func TestExtractDiscussionTopics_AIError(t *testing.T) {
	p := newExtractPipeline("", errFakeAI)
	_, err := p.ExtractDiscussionTopics(context.Background(), "raw", "")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "AI generation")
}

func TestTrimNonEmpty(t *testing.T) {
	got := trimNonEmpty([]string{"", "  ", "  hello  ", "world"})
	assert.Equal(t, []string{"hello", "world"}, got)
}

// errFakeAI is a sentinel error used to simulate AI generator failures.
var errFakeAI = errFakeAIType{}

type errFakeAIType struct{}

func (errFakeAIType) Error() string { return "fake ai failure" }
