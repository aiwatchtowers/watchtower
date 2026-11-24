package sessionfeed

import (
	"fmt"
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

func TestParse_NoticesAreEvents(t *testing.T) {
	res := parseStr(t, join(
		userStr("n1", "<task-notification>\n<task-id>t1</task-id>\n<status>completed</status>\n<summary>Background command \"Wait for CI\" completed (exit code 0)</summary>\n</task-notification>"),
		userStr("n2", "<teammate-message teammate_id=\"lane-1\" color=\"green\" summary=\"#1 PR opened\">\n#1 is ready: PR #2\n</teammate-message>"),
	), 0)
	require.Len(t, res.Entries, 2)
	for _, e := range res.Entries {
		assert.Equal(t, KindEvent, e.Kind)
	}
	task, mate := res.Entries[0], res.Entries[1]
	assert.Equal(t, EventTask, task.EventType)
	assert.Equal(t, `Background command "Wait for CI" completed (exit code 0)`, task.Title)
	assert.Contains(t, task.Text, "status: completed")
	assert.Contains(t, task.Text, "task-id: t1")
	assert.NotContains(t, task.Text, "<task-id>")
	assert.Equal(t, EventTeammate, mate.EventType)
	assert.Equal(t, "#1 PR opened", mate.Title)
	assert.Equal(t, "#1 is ready: PR #2", mate.Text)
	assert.Equal(t, "n2", mate.ID)
	assert.Equal(t, "conv1", mate.Conversation)
}

func TestParse_NoticeWithoutSummaryHasFallbackTitle(t *testing.T) {
	res := parseStr(t, join(
		userStr("n1", "<task-notification>\n<task-id>t2</task-id>\n</task-notification>"),
		userStr("n2", "<teammate-message teammate_id=\"x\">\n\nhello\n</teammate-message>"),
		userStr("n3", "<task-notification></task-notification>"),
	), 0)
	require.Len(t, res.Entries, 3)
	assert.Equal(t, "task-id: t2", res.Entries[0].Title)
	assert.Equal(t, "hello", res.Entries[1].Title)
	assert.Equal(t, "Notice", res.Entries[2].Title)
}

func TestParse_NoticeAfterOwnerTextStaysOwner(t *testing.T) {
	text := "please look\n<task-notification>\n<task-id>t1</task-id>\n</task-notification>"
	res := parseStr(t, join(userStr("u1", text)), 0)
	require.Len(t, res.Entries, 1)
	assert.Equal(t, KindOwner, res.Entries[0].Kind)
	assert.Equal(t, text, res.Entries[0].Text)
}

func queuedRec(uuid string, extra map[string]any, att map[string]any) string {
	a := map[string]any{"type": "queued_command", "commandMode": "prompt",
		"origin": map[string]any{"kind": "human"}, "humanTurn": true}
	for k, v := range att {
		if v == nil {
			delete(a, k)
		} else {
			a[k] = v
		}
	}
	rec := map[string]any{"type": "attachment", "uuid": uuid, "timestamp": "2026-10-01T10:00:00Z", "attachment": a}
	for k, v := range extra {
		rec[k] = v
	}
	return jsonLine(rec)
}

func TestParse_QueuedHumanPromptIsOwner(t *testing.T) {
	res := parseStr(t, queuedRec("q1", nil, map[string]any{"prompt": "run the tests"}), 0)
	require.Len(t, res.Entries, 1)
	e := res.Entries[0]
	assert.Equal(t, "q1", e.ID)
	assert.Equal(t, KindOwner, e.Kind)
	assert.Equal(t, "run the tests", e.Text)
	assert.Equal(t, "2026-10-01T10:00:00Z", e.At.UTC().Format("2006-01-02T15:04:05Z"))
}

func TestParse_QueuedPromptWithoutOriginIsOwner(t *testing.T) {
	res := parseStr(t, queuedRec("q1", nil, map[string]any{"prompt": "go on", "origin": nil}), 0)
	require.Len(t, res.Entries, 1)
	assert.Equal(t, KindOwner, res.Entries[0].Kind)
	assert.Equal(t, "go on", res.Entries[0].Text)
}

func TestParse_QueuedPromptBlocksWithImage(t *testing.T) {
	res := parseStr(t, queuedRec("q1", nil, map[string]any{"prompt": []any{textB("look"), map[string]any{"type": "image"}}}), 0)
	require.Len(t, res.Entries, 1)
	assert.Equal(t, "look\n[image]", res.Entries[0].Text)
}

func TestParse_QueuedAskAnswerIsAskAnswer(t *testing.T) {
	res := parseStr(t, queuedRec("q1", nil, map[string]any{"prompt": askLine(9)}), 0)
	require.Len(t, res.Entries, 1)
	assert.Equal(t, KindAskAnswer, res.Entries[0].Kind)
	assert.Equal(t, int64(9), res.Entries[0].AskID)
}

func TestParse_QueuedNonHumanIgnored(t *testing.T) {
	res := parseStr(t, join(
		queuedRec("q1", nil, map[string]any{"commandMode": "task-notification", "prompt": "done"}),
		queuedRec("q2", map[string]any{"isMeta": true}, map[string]any{"origin": map[string]any{"kind": "peer"}, "prompt": "hi"}),
		queuedRec("q3", nil, map[string]any{"origin": map[string]any{"kind": "coordinator"}, "prompt": "hi"}),
	), 0)
	assert.Empty(t, res.Entries)
	assert.Empty(t, res.Unknown)
}

func TestParse_QueuedSidechainIgnoredInMain(t *testing.T) {
	res := parseStr(t, queuedRec("q1", map[string]any{"isSidechain": true}, map[string]any{"prompt": "side"}), 0)
	assert.Empty(t, res.Entries)
}

// A transcript longer than one decode batch is decoded in parallel and still
// handled in file order: entries keep their order, a message streamed across
// a batch boundary merges into one entry, invalid and over-long lines are
// counted, and the offset covers every complete line (a partial tail is not
// read).
func TestParse_ParallelBatchesKeepFileOrder(t *testing.T) {
	var b strings.Builder
	b.WriteString(assistantRec("a0", "m0", textB("start")))
	want := []string{"start"}
	invalid, skipped := 0, 0
	for i := 1; i <= 3*decodeBatchLines; i++ {
		switch {
		case i%97 == 0:
			b.WriteString("not json\n")
			invalid++
		case i%211 == 0:
			b.WriteString(userStr(fmt.Sprintf("long%d", i), repeat("x", 600)))
			skipped++
		default:
			text := fmt.Sprintf("line %d", i)
			b.WriteString(userStr(fmt.Sprintf("u%d", i), text))
			want = append(want, text)
		}
	}
	// the first message grows after a few batches: one entry, first place
	b.WriteString(assistantRec("a1", "m0", textB("start"), textB("end")))
	want[0] = "start\n\nend"
	full := b.String()
	in := full + `{"type":"user"` // a partial last line

	res, err := parse(strings.NewReader(in), 7, "conv1", 400)
	require.NoError(t, err)
	got := make([]string, 0, len(res.Entries))
	for _, e := range res.Entries {
		got = append(got, e.Text)
	}
	assert.Equal(t, want, got)
	assert.Equal(t, map[string]int{"<invalid>": invalid}, res.Unknown)
	assert.Equal(t, skipped, res.Skipped)
	assert.Equal(t, int64(7+len(full)), res.Offset)
}

// BenchmarkParse is a manual throughput benchmark of a large pane's first
// open (run it with -bench; nothing fails on a slowdown, so it is not a
// regression guard): a ~1,000-entry transcript of the record mix a long Claude Code session writes
// (owner lines, streamed agent text, tool calls and results, ignored types).
func BenchmarkParse(b *testing.B) {
	var sb strings.Builder
	result := repeat("r", 4000)
	for i := range 500 {
		sb.WriteString(userStr(fmt.Sprintf("u%d", i), fmt.Sprintf("owner line %d", i)))
		sb.WriteString(assistantRec(fmt.Sprintf("a%d", i), fmt.Sprintf("m%d", i), textB(repeat("t", 800))))
		sb.WriteString(assistantRec(fmt.Sprintf("c%d", i), fmt.Sprintf("n%d", i),
			map[string]any{"type": "tool_use", "id": fmt.Sprintf("tu%d", i), "name": "Read", "input": map[string]any{"file_path": "/w/f.go"}}))
		sb.WriteString(userBlocks(fmt.Sprintf("r%d", i),
			map[string]any{"type": "tool_result", "tool_use_id": fmt.Sprintf("tu%d", i), "content": result}))
		sb.WriteString(jsonLine(map[string]any{"type": "queue-operation", "operation": "enqueue", "content": repeat("q", 1000)}))
		sb.WriteString(jsonLine(map[string]any{"type": "api-request-blob", "blob": map[string]any{"body": repeat("b", 4000)}}))
		sb.WriteString(jsonLine(map[string]any{"type": "attachment", "attachment": map[string]any{"type": "hook_success", "stdout": repeat("s", 4000)}}))
	}
	in := sb.String()
	b.SetBytes(int64(len(in)))
	b.ResetTimer()
	for b.Loop() {
		if _, err := Parse(strings.NewReader(in), 0, "conv1"); err != nil {
			b.Fatal(err)
		}
	}
}

const agentNotice = "<task-notification>\n<task-id>aaea0001</task-id>\n<tool-use-id>toolu_01abc</tool-use-id>\n<output-file>/tmp/x.output</output-file>\n<status>completed</status>\n<summary>Agent \"Verify review #1\" finished</summary>\n<note>read the output file</note>\n<result>This agent's report was delivered to you as a message from \"aaea0001\".</result>\n<usage><subagent_tokens>43545</subagent_tokens><tool_uses>9</tool_uses><duration_ms>88925</duration_ms></usage>\n</task-notification>"

func TestNoticeTask_Fields(t *testing.T) {
	res := parseStr(t, join(userStr("n1", agentNotice)), 0)
	require.Len(t, res.Entries, 1)
	e := res.Entries[0]
	require.NotNil(t, e.Task)
	assert.Equal(t, TaskRef{
		TaskID: "aaea0001", ToolUseID: "toolu_01abc", Status: "completed",
		Summary: `Agent "Verify review #1" finished`, Result: "", OutputFile: "/tmp/x.output",
		Tokens: 43545, ToolUses: 9, DurationMS: 88925, Kind: "agent",
	}, *e.Task)
	assert.Equal(t, `Agent "Verify review #1" finished`, e.Title)
	assert.Contains(t, e.Text, "status: completed")
	assert.Contains(t, e.Text, "task-id: aaea0001")
}

func TestNoticeTask_CurlyBoilerplateIsEmptyResult(t *testing.T) {
	n := strings.Replace(agentNotice, "agent's", "agent’s", 1)
	res := parseStr(t, join(userStr("n1", n)), 0)
	require.NotNil(t, res.Entries[0].Task)
	assert.Equal(t, "", res.Entries[0].Task.Result)
}

func TestNoticeTask_RealResultKept(t *testing.T) {
	n := strings.Replace(agentNotice, `This agent's report was delivered to you as a message from "aaea0001".`, "All green.", 1)
	res := parseStr(t, join(userStr("n1", n)), 0)
	require.NotNil(t, res.Entries[0].Task)
	assert.Equal(t, "All green.", res.Entries[0].Task.Result)
}

func TestNoticeTask_Command(t *testing.T) {
	res := parseStr(t, join(userStr("n1", "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n<summary>Background command \"Run full Go test suite\" completed (exit code 0)</summary>\n</task-notification>")), 0)
	require.NotNil(t, res.Entries[0].Task)
	assert.Equal(t, "command", res.Entries[0].Task.Kind)
	require.NotNil(t, res.Entries[0].Task.ExitCode)
	assert.Equal(t, 0, *res.Entries[0].Task.ExitCode)
}

func TestNoticeTask_NoUsage(t *testing.T) {
	res := parseStr(t, join(userStr("n1", "<task-notification>\n<task-id>a1</task-id>\n<status>failed</status>\n<summary>Agent \"X\" failed</summary>\n</task-notification>")), 0)
	require.NotNil(t, res.Entries[0].Task)
	assert.Equal(t, 0, res.Entries[0].Task.Tokens)
	assert.Equal(t, "failed", res.Entries[0].Task.Status)
	assert.Equal(t, `Agent "X" failed`, res.Entries[0].Task.Summary)
}

func TestNoticeTask_Truncated(t *testing.T) {
	res := parseStr(t, join(userStr("n1", "<task-notification>\n<task-id>a1</task-id>\n<status>comp")), 0)
	require.Len(t, res.Entries, 1)
	assert.Equal(t, KindEvent, res.Entries[0].Kind)
	assert.Nil(t, res.Entries[0].Task)
}

func TestNoticeTask_TrailingTextAfterClose(t *testing.T) {
	res := parseStr(t, join(userStr("n1", agentNotice+"\nRead the output file to retrieve the result.")), 0)
	require.Len(t, res.Entries, 1)
	require.NotNil(t, res.Entries[0].Task)
	assert.Equal(t, 43545, res.Entries[0].Task.Tokens)
}

func TestNoticeTask_MismatchedChildIsNil(t *testing.T) {
	res := parseStr(t, join(userStr("n1", "<task-notification>\n<task-id>a1</task-id>\n<status>done</summary>\n</task-notification>")), 0)
	require.Len(t, res.Entries, 1)
	assert.Nil(t, res.Entries[0].Task)
}

func TestNoticeTask_NestedTagInResultKept(t *testing.T) {
	n := strings.Replace(agentNotice, `This agent's report was delivered to you as a message from "aaea0001".`, "Found <b>3</b> issues in <file>x</file>.", 1)
	res := parseStr(t, join(userStr("n1", n)), 0)
	require.NotNil(t, res.Entries[0].Task)
	assert.Equal(t, "Found <b>3</b> issues in <file>x</file>.", res.Entries[0].Task.Result)
	assert.Equal(t, 43545, res.Entries[0].Task.Tokens)
}

func TestNoticeTask_UsageOnlyFromUsageElement(t *testing.T) {
	n := "<task-notification>\n<task-id>a1</task-id>\n<status>completed</status>\n<summary>Agent \"X\" finished</summary>\n<result>did <tool_uses>77</tool_uses> things</result>\n</task-notification>"
	res := parseStr(t, join(userStr("n1", n)), 0)
	require.NotNil(t, res.Entries[0].Task)
	assert.Equal(t, 0, res.Entries[0].Task.ToolUses)
}

func TestNoticeTask_ExitCodeAnchoredToEnd(t *testing.T) {
	n := "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n<summary>Background command \"echo (exit code 9)\" completed (exit code 3)</summary>\n</task-notification>"
	res := parseStr(t, join(userStr("n1", n)), 0)
	require.NotNil(t, res.Entries[0].Task.ExitCode)
	assert.Equal(t, 3, *res.Entries[0].Task.ExitCode)
}

func TestNoticeTask_ResultQuotingWholeNotification(t *testing.T) {
	quoted := "<task-notification>\n<task-id>zz</task-id>\n<status>failed</status>\n</task-notification>"
	n := strings.Replace(agentNotice, `This agent's report was delivered to you as a message from "aaea0001".`, "It printed: "+quoted, 1)
	res := parseStr(t, join(userStr("n1", n)), 0)
	require.NotNil(t, res.Entries[0].Task)
	assert.Equal(t, "aaea0001", res.Entries[0].Task.TaskID)
	assert.Equal(t, "completed", res.Entries[0].Task.Status)
	assert.Equal(t, "It printed: "+quoted, res.Entries[0].Task.Result)
	assert.Equal(t, 43545, res.Entries[0].Task.Tokens)
}
