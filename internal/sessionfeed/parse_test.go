package sessionfeed

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/reviewdiff"
)

func parseStr(t *testing.T, s string, off int64) *Result {
	t.Helper()
	res, err := Parse(strings.NewReader(s), off, "conv1")
	require.NoError(t, err)
	return res
}

func TestParse_OwnerAndAgentOnly(t *testing.T) {
	in := join(
		userStr("u1", "hello"),
		assistantRec("a1", "m1",
			map[string]any{"type": "thinking", "thinking": "hmm"}, textB("A"),
			map[string]any{"type": "tool_use", "id": "t1", "name": "Bash"}),
		userBlocks("u2", map[string]any{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}),
		metaUser("u3", "meta"),
	)
	res := parseStr(t, in, 0)
	require.Len(t, res.Entries, 2)
	assert.Equal(t, KindOwner, res.Entries[0].Kind)
	assert.Equal(t, "hello", res.Entries[0].Text)
	assert.Equal(t, KindAgent, res.Entries[1].Kind)
	assert.Equal(t, "A", res.Entries[1].Text)
	assert.Equal(t, "m1", res.Entries[1].ID)
	assert.Equal(t, "conv1", res.Entries[1].Conversation)
	assert.Equal(t, int64(len(in)), res.Offset)
}

func TestParse_StreamedMessageOnce(t *testing.T) {
	in := join(
		assistantRec("a1", "m1", textB("He")),
		userStr("u1", "interleaved"),
		assistantRec("a2", "m1", textB("Hello")),
		assistantRec("a3", "m1", textB("Hello"), textB("world")),
	)
	res := parseStr(t, in, 0)
	require.Len(t, res.Entries, 2)
	assert.Equal(t, "m1", res.Entries[0].ID)
	assert.Equal(t, "Hello\n\nworld", res.Entries[0].Text)
	assert.Equal(t, KindOwner, res.Entries[1].Kind)
}

func TestParse_StripsSystemReminder(t *testing.T) {
	res := parseStr(t, join(
		userStr("u1", "hi<system-reminder>x</system-reminder>"),
		userStr("u2", "<system-reminder>only</system-reminder>"),
	), 0)
	require.Len(t, res.Entries, 1)
	assert.Equal(t, "hi", res.Entries[0].Text)
}

func TestParse_SlashCommand(t *testing.T) {
	res := parseStr(t, join(
		userStr("u1", "<command-name>/review</command-name><command-args>42</command-args>"),
		userStr("u2", "<local-command-stdout>x</local-command-stdout>"),
		userStr("u3", "[Request interrupted by user]"),
	), 0)
	require.Len(t, res.Entries, 1)
	assert.Equal(t, "/review 42", res.Entries[0].Text)
	assert.Equal(t, KindOwner, res.Entries[0].Kind)
}

func TestParse_WatchtowerLines(t *testing.T) {
	res := parseStr(t, join(
		userStr("u1", askLine(7)),
		userStr("u2", "Review round #3 sent (2 comments) — read it with get_review 3 using the skill."),
		userStr("u3", "From a Watchtower code question: where is X?"),
	), 0)
	require.Len(t, res.Entries, 3)
	assert.Equal(t, KindAskAnswer, res.Entries[0].Kind)
	assert.Equal(t, int64(7), res.Entries[0].AskID)
	assert.Equal(t, askLine(7), res.Entries[0].Text)
	assert.Equal(t, KindWatchtower, res.Entries[1].Kind)
	assert.Equal(t, "review", res.Entries[1].Via)
	assert.Equal(t, KindWatchtower, res.Entries[2].Kind)
	assert.Equal(t, "handoff", res.Entries[2].Via)
}

func TestParse_Brief(t *testing.T) {
	res := parseStr(t, join(
		briefAttachment("b1", "SessionStart", "Watchtower workbench #4 brief"),
		briefAttachment("b2", "SessionStart", "some skill plugin output"),
		briefAttachment("b3", "PreToolUse", "Watchtower workbench #4 brief"),
	), 0)
	require.Len(t, res.Entries, 1)
	assert.Equal(t, KindBrief, res.Entries[0].Kind)
	assert.Equal(t, "b1", res.Entries[0].ID)
	assert.Empty(t, res.Unknown)
}

func TestParse_PartialLastLine(t *testing.T) {
	first := userStr("u1", "one")
	in := first + strings.TrimSuffix(userStr("u2", "two"), "\n")
	res := parseStr(t, in, 0)
	require.Len(t, res.Entries, 1)
	assert.Equal(t, int64(len(first)), res.Offset)
}

func TestParse_StartOffset(t *testing.T) {
	first := userStr("u1", "one")
	in := first + userStr("u2", "two")
	res := parseStr(t, in[len(first):], int64(len(first)))
	require.Len(t, res.Entries, 1)
	assert.Equal(t, "two", res.Entries[0].Text)
	assert.Equal(t, int64(len(in)), res.Offset)
}

func TestParse_OverlongLineSkipped(t *testing.T) {
	long := userStr("u1", repeat("x", 500))
	in := long + userStr("u2", "after")
	res, err := parse(strings.NewReader(in), 0, "c", 200)
	require.NoError(t, err)
	assert.Equal(t, 1, res.Skipped)
	require.Len(t, res.Entries, 1)
	assert.Equal(t, "after", res.Entries[0].Text)
	assert.Equal(t, int64(len(in)), res.Offset)
}

func TestParse_UnknownTypes(t *testing.T) {
	res := parseStr(t, "{\"type\":\"mystery\"}\n{\"type\":\"api-request-blob\"}\n{\"type\":\"mode\"}\nnot json\n", 0)
	assert.Equal(t, map[string]int{"mystery": 1, "<invalid>": 1}, res.Unknown)
}

func TestParse_ImageAndSidechain(t *testing.T) {
	res := parseStr(t, join(
		userBlocks("u1", textB("see"), map[string]any{"type": "image"}),
		jsonLine(map[string]any{"type": "assistant", "uuid": "s", "isSidechain": true,
			"message": map[string]any{"id": "ms", "content": []any{textB("side")}}}),
	), 0)
	require.Len(t, res.Entries, 1)
	assert.Equal(t, "see\n[image]", res.Entries[0].Text)
}

func TestParse_KnownIgnoredTypes(t *testing.T) {
	res := parseStr(t, "{\"type\":\"atis-latch\"}\n{\"type\":\"frame-link\"}\n{\"type\":\"queue-operation\"}\n{\"type\":\"file-history-delta\"}\n{\"type\":\"artifact-view\"}\n{\"type\":\"mystery\"}\n", 0)
	assert.Equal(t, map[string]int{"mystery": 1}, res.Unknown)
}

func TestParse_PastedImageMarkerNotDoubled(t *testing.T) {
	res := parseStr(t, join(
		userBlocks("u1", textB("[Image #1] look"), map[string]any{"type": "image"}),
	), 0)
	require.Len(t, res.Entries, 1)
	assert.Equal(t, "[Image #1] look", res.Entries[0].Text)
}

func TestParse_ReviewPrefixMatchesDeliveryLine(t *testing.T) {
	assert.True(t, strings.HasPrefix(reviewdiff.DeliveryLine(3, 2), reviewPrefix))
}
