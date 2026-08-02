package memory

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// fakeMsgChecker resolves (channel_id, ts) membership from a fixed set — the
// gap-message resolver seam for MEM-13 (an episode-cited ref never reaches it).
type fakeMsgChecker map[string]bool

func (f fakeMsgChecker) MessageExists(channelID, ts string) (bool, error) {
	return f[channelID+"\x00"+ts], nil
}

// renderPipeline builds a minimal pipeline for render tests: the fake generator
// returns reply(user), and checkMsg resolves the given gap messages.
func renderPipeline(t *testing.T, reply func(string) (string, error), gap fakeMsgChecker) *Pipeline {
	t.Helper()
	v, d := newTestVault(t), newTestDB(t)
	p := NewPipeline(d, v, &fakeGen{reply: reply}, pipelineTestConfig(), t.Logf)
	if gap != nil {
		p.checkMsg = gap
	}
	return p
}

// twoEpisodes is the canonical render input: two episodes on channel C0AAA, each
// citing one provenance ts.
func twoEpisodes() []renderEpisode {
	return []renderEpisode{
		{Title: "Rollout incident", Story: "The deploy broke prod.", Outcome: "Rolled back.", Provenance: []string{"100.000100"}},
		{Title: "Budget agreed", Story: "Team agreed the Q3 budget.", Outcome: "Signed off.", Provenance: []string{"200.000200"}},
	}
}

// TestRenderChannelDigest_HappyPath: a window of two episodes renders a digest
// whose key_messages are exactly the episodes' provenance ts, nothing rejected,
// and whose JSON is shape-compatible with the legacy digest_topics schema
// (it unmarshals cleanly into digest.DigestResult).
func TestRenderChannelDigest_HappyPath(t *testing.T) {
	reply := func(string) (string, error) {
		return `{"summary":"Two things happened.","topics":[
			{"title":"Rollout incident","summary":"Deploy broke, rolled back.","decisions":[{"text":"Roll back","by":"U1","message_ts":"100.000100","importance":"high"}],"action_items":[{"text":"Add canary","assignee":"U2","status":"open"}],"situations":[],"key_messages":["100.000100"]},
			{"title":"Budget agreed","summary":"Q3 budget signed.","decisions":[],"action_items":[],"situations":[],"key_messages":["200.000200"]}
		]}`, nil
	}
	p := renderPipeline(t, reply, nil)

	rd, rejected, usage, err := p.renderChannelDigest(context.Background(), "C0AAA", twoEpisodes(), nil)
	require.NoError(t, err)
	assert.Equal(t, 0, rejected, "every cited ts is episode-cited")
	require.NotNil(t, usage)
	require.Len(t, rd.Topics, 2)
	assert.Equal(t, []string{"100.000100"}, rd.Topics[0].KeyMessages)
	assert.Equal(t, []string{"200.000200"}, rd.Topics[1].KeyMessages)

	// Shape parity: the render marshals to the legacy digest_topics JSON — it
	// must round-trip through the legacy struct (the future drop-in switch).
	raw, err := json.Marshal(rd)
	require.NoError(t, err)
	var legacy digest.DigestResult
	require.NoError(t, json.Unmarshal(raw, &legacy), "render JSON must fit the legacy DigestResult")
	assert.Equal(t, "Two things happened.", legacy.Summary)
	require.Len(t, legacy.Topics, 2)
	assert.Equal(t, "Rollout incident", legacy.Topics[0].Title)
	require.Len(t, legacy.Topics[0].Decisions, 1)
	assert.Equal(t, "100.000100", legacy.Topics[0].Decisions[0].MessageTS)
	assert.Equal(t, []string{"100.000100"}, legacy.Topics[0].KeyMessages)
}

// TestMemory13_RenderCitesOnlyEpisodeProvenance guards the MEM-13 kernel: a
// render ref survives only when episode-cited OR a resolving raw gap-message
// ts; an invented ref is dropped-and-counted, the surviving refs still written.
func TestMemory13_RenderCitesOnlyEpisodeProvenance(t *testing.T) {
	t.Run("invented ref dropped and counted", func(t *testing.T) {
		reply := func(string) (string, error) {
			// key_messages cite one episode ts (valid) + one invented ts; the
			// decision cites an invented ts.
			return `{"summary":"s","topics":[
				{"title":"T","summary":"x","decisions":[{"text":"d","by":"U1","message_ts":"999.999999","importance":"low"}],"action_items":[],"situations":[],"key_messages":["100.000100","888.888888"]}
			]}`, nil
		}
		p := renderPipeline(t, reply, nil)
		rd, rejected, _, err := p.renderChannelDigest(context.Background(), "C0AAA", twoEpisodes(), nil)
		require.NoError(t, err)
		assert.Equal(t, 2, rejected, "the invented key_message and the invented decision ref are both counted")
		require.Len(t, rd.Topics, 1)
		assert.Equal(t, []string{"100.000100"}, rd.Topics[0].KeyMessages, "only the episode-cited ts survives")
		assert.Empty(t, rd.Topics[0].Decisions, "the decision citing an invented ts is dropped")
	})

	t.Run("resolving gap-message ts kept", func(t *testing.T) {
		reply := func(string) (string, error) {
			// Cite a ts that is NOT in any episode but IS a real message in the
			// channel (a coverage-gap message) — it resolves and is kept.
			return `{"summary":"s","topics":[
				{"title":"T","summary":"x","decisions":[],"action_items":[],"situations":[],"key_messages":["500.000500"]}
			]}`, nil
		}
		gap := fakeMsgChecker{"C0AAA\x00500.000500": true}
		p := renderPipeline(t, reply, gap)
		gapMsgs := []gapMessage{{TS: "500.000500", Author: "U9", Text: "an uncovered decision"}}
		rd, rejected, _, err := p.renderChannelDigest(context.Background(), "C0AAA", twoEpisodes(), gapMsgs)
		require.NoError(t, err)
		assert.Equal(t, 0, rejected)
		require.Len(t, rd.Topics, 1)
		assert.Equal(t, []string{"500.000500"}, rd.Topics[0].KeyMessages, "the resolving gap ts is kept")
	})

	t.Run("all-refs-invalid topic dropped", func(t *testing.T) {
		reply := func(string) (string, error) {
			// One topic cites only invented ts (dropped entirely); one topic is
			// clean (survives).
			return `{"summary":"s","topics":[
				{"title":"Hallucinated","summary":"x","decisions":[{"text":"d","by":"U1","message_ts":"777.777777","importance":"low"}],"action_items":[],"situations":[],"key_messages":["666.666666"]},
				{"title":"Real","summary":"y","decisions":[],"action_items":[],"situations":[],"key_messages":["200.000200"]}
			]}`, nil
		}
		p := renderPipeline(t, reply, nil)
		rd, rejected, _, err := p.renderChannelDigest(context.Background(), "C0AAA", twoEpisodes(), nil)
		require.NoError(t, err)
		assert.Equal(t, 2, rejected, "both refs of the hallucinated topic are counted")
		require.Len(t, rd.Topics, 1, "the topic whose refs were all invented is dropped")
		assert.Equal(t, "Real", rd.Topics[0].Title)
	})
}

// TestRenderChannelDigest_GarbageJSON: a reply with no JSON object errors (the
// caller isolates it in Task 5; it never writes a shadow row).
func TestRenderChannelDigest_GarbageJSON(t *testing.T) {
	p := renderPipeline(t, func(string) (string, error) { return "sorry, no can do", nil }, nil)
	_, _, _, err := p.renderChannelDigest(context.Background(), "C0AAA", twoEpisodes(), nil)
	require.Error(t, err)
}

// TestBuildRenderPromptNeverStartsWithDash + content assertions: the user
// message must not open with a dash (claude-CLI argv gotcha) and must surface
// each episode's provenance ts and the gap messages so the model can cite only
// shown timestamps.
func TestBuildRenderPromptContent(t *testing.T) {
	tmpl := prompts.DefaultFor(prompts.MemoryRenderChannelDigest)
	require.NotEmpty(t, tmpl)
	gapMsgs := []gapMessage{{TS: "500.000500", Author: "U9", Text: "uncovered"}}
	system, user := buildRenderPrompt(tmpl, "", "C0AAA", twoEpisodes(), gapMsgs)

	assert.False(t, strings.HasPrefix(user, "-"), "render user message must not start with '-'")
	assert.True(t, prompts.HasDirective(system), "the system prompt carries the language directive")
	assert.Contains(t, user, "100.000100", "episode provenance ts is shown")
	assert.Contains(t, user, "200.000200")
	assert.Contains(t, user, "500.000500", "the gap message ts is shown")
	assert.Contains(t, user, "Rollout incident", "episode title is shown")
}
