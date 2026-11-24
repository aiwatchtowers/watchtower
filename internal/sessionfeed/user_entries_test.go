package sessionfeed

import (
	"encoding/json"
	"fmt"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func textBlock(s string) map[string]any { return map[string]any{"type": "text", "text": s} }

const (
	siblingA = "<task-notification>\n<task-id>a1</task-id>\n<status>completed</status>\n<summary>Agent \"A\" finished</summary>\n<result>done A</result>\n</task-notification>"
	siblingB = "<task-notification>\n<task-id>b2</task-id>\n<status>failed</status>\n<summary>Agent \"B\" failed</summary>\n<result>done B</result>\n</task-notification>"
)

// Fix round 4 (codex P2): two notice blocks beside an ordinary text block stay
// one entry, and that entry is the leading notice read within its own block —
// its result does not swallow the second notice.
func TestNoticeTask_MixedRecordReadsTheLeadingNoticeInItsBlock(t *testing.T) {
	res := parseStr(t, userBlocks("n1", textBlock(siblingA), textBlock(siblingB), textBlock("and also this")), 0)
	require.Len(t, res.Entries, 1)
	e := res.Entries[0]
	assert.Equal(t, "n1", e.ID)
	assert.Equal(t, KindEvent, e.Kind)
	require.NotNil(t, e.Task)
	assert.Equal(t, "a1", e.Task.TaskID)
	assert.Equal(t, "done A", e.Task.Result)
	assert.Equal(t, "completed", e.Task.Status)
	assert.NotContains(t, e.Text, "b2")
}

// Fix round 4 (codex P2, FEED-02): a system reminder that spans notice blocks
// is removed whole; a notice quoted inside it is not an event.
func TestNoticeTask_ReminderSpanningBlocksIsStripped(t *testing.T) {
	quoted := "<task-notification>\n<task-id>q9</task-id>\n<summary>quoted</summary>\n</task-notification>"
	res := parseStr(t, userBlocks("n1",
		textBlock(siblingA+"\n<system-reminder>An earlier notice said:"),
		textBlock(quoted+"\n</system-reminder>"),
	), 0)
	require.Len(t, res.Entries, 1)
	e := res.Entries[0]
	assert.Equal(t, "n1", e.ID)
	require.NotNil(t, e.Task)
	assert.Equal(t, "a1", e.Task.TaskID)
	assert.NotContains(t, e.Text, "q9")
	assert.NotContains(t, e.Text, "system-reminder")
	assert.NotContains(t, e.Text, "An earlier notice")
}

// A reminder inside one notice block does not stop the split.
func TestNoticeTask_ReminderInsideABlockStillSplits(t *testing.T) {
	res := parseStr(t, userBlocks("n1",
		textBlock(siblingA+"\n<system-reminder>x</system-reminder>"),
		textBlock("<system-reminder>y</system-reminder>\n"+siblingB),
	), 0)
	require.Len(t, res.Entries, 2)
	require.NotNil(t, res.Entries[0].Task)
	require.NotNil(t, res.Entries[1].Task)
	assert.Equal(t, "a1", res.Entries[0].Task.TaskID)
	assert.Equal(t, "b2", res.Entries[1].Task.TaskID)
}

// Fix round 4 (codex P3): a sibling's id suffix is its content block's index
// in the message, counting the blocks that give no entry.
func TestNoticeTask_SiblingIDIsTheSourceBlockIndex(t *testing.T) {
	res := parseStr(t, userBlocks("n1",
		textBlock(siblingA),
		textBlock("<system-reminder>only a reminder</system-reminder>"),
		textBlock(siblingB),
	), 0)
	require.Len(t, res.Entries, 2)
	assert.Equal(t, "n1", res.Entries[0].ID)
	assert.Equal(t, "n1#2", res.Entries[1].ID)
	require.NotNil(t, res.Entries[1].Task)
	assert.Equal(t, "b2", res.Entries[1].Task.TaskID)
}

// Fix rounds 4–5 (codex P2): a user record's content is decoded once for all
// of handleUser's readers, tool results included. Relative: handling a record
// of many tool results allocates less than 1.5 times one decode of its content
// plus the read of each result.
func TestHandleUser_DecodesContentOnce(t *testing.T) {
	var sb strings.Builder
	sb.WriteByte('[')
	for i := range 300 {
		if i > 0 {
			sb.WriteByte(',')
		}
		fmt.Fprintf(&sb, `{"type":"tool_result","tool_use_id":"t%d","is_error":true,"content":"out %d"}`, i, i)
	}
	sb.WriteByte(']')
	var rec record
	rec.UUID = "u1"
	rec.Message.Content = json.RawMessage(sb.String())
	once := testing.AllocsPerRun(20, func() {
		var bs []block
		_ = json.Unmarshal(rec.Message.Content, &bs)
		for _, b := range bs {
			_ = resultText(b.Content)
		}
	})
	st := newState("conv1", 0, false)
	got := testing.AllocsPerRun(20, func() { st.handleUser(rec, time.Time{}) })
	assert.Empty(t, st.res.Entries, "a tool-result record gives no entry")
	assert.Less(t, got, once*1.5, "one decode of the content, not three (one decode = %v allocations)", once)
}

// Notices beside an image stay one entry, the leading notice read in its block.
func TestNoticeTask_NoticesBesideAnImageStayOneEntry(t *testing.T) {
	res := parseStr(t, userBlocks("n1", textBlock(siblingA), textBlock(siblingB), map[string]any{"type": "image"}), 0)
	require.Len(t, res.Entries, 1)
	assert.Equal(t, "n1", res.Entries[0].ID)
	require.NotNil(t, res.Entries[0].Task)
	assert.Equal(t, "done A", res.Entries[0].Task.Result)
}

// Fix round 5 (codex P2): a notice that continues in the next block is read
// from the joined text, so its later children are kept.
func TestNoticeTask_NoticeContinuingInTheNextBlockIsJoined(t *testing.T) {
	res := parseStr(t, userBlocks("n1",
		textBlock("<task-notification>\n<task-id>a1</task-id>\n<summary>Agent \"A\" finished</summary>"),
		textBlock("<result>done A</result>\n</task-notification>"),
	), 0)
	require.Len(t, res.Entries, 1)
	e := res.Entries[0]
	assert.Equal(t, "n1", e.ID)
	require.NotNil(t, e.Task)
	assert.Equal(t, "a1", e.Task.TaskID)
	assert.Equal(t, "done A", e.Task.Result)
}

// The same when the continuation itself starts with a quoted notification.
func TestNoticeTask_IncompleteNoticeBlockIsNotSplit(t *testing.T) {
	res := parseStr(t, userBlocks("n1",
		textBlock("<task-notification>\n<task-id>a1</task-id>\n<result>"),
		textBlock(siblingB+"\n</result>\n<status>completed</status>\n</task-notification>"),
	), 0)
	require.Len(t, res.Entries, 1)
	require.NotNil(t, res.Entries[0].Task)
	assert.Equal(t, "a1", res.Entries[0].Task.TaskID)
	assert.Equal(t, "completed", res.Entries[0].Task.Status)
}

// Fix round 5 (codex P2): one notice beside an image is the notice alone — no
// image marker and no close tag in the event's text.
func TestNotice_SingleNoticeBesideAnImage(t *testing.T) {
	mate := `<teammate-message teammate_id="rev" summary="Review done">` + "\nLooks good.\n</teammate-message>"
	res := parseStr(t, join(
		userBlocks("m1", textBlock(mate), map[string]any{"type": "image"}),
		userBlocks("t1", textBlock(siblingA), map[string]any{"type": "image"}),
	), 0)
	require.Len(t, res.Entries, 2)
	assert.Equal(t, KindEvent, res.Entries[0].Kind)
	assert.Equal(t, "Review done", res.Entries[0].Title)
	assert.Equal(t, "Looks good.", res.Entries[0].Text)
	require.NotNil(t, res.Entries[1].Task)
	assert.Equal(t, "done A", res.Entries[1].Task.Result)
	assert.NotContains(t, res.Entries[1].Text, "[image]")
}

// An ordinary message of several blocks with an image keeps its marker.
func TestParse_MultiBlockOwnerTextWithImage(t *testing.T) {
	res := parseStr(t, userBlocks("u1", textBlock("first"), textBlock("second"), map[string]any{"type": "image"}), 0)
	require.Len(t, res.Entries, 1)
	assert.Equal(t, KindOwner, res.Entries[0].Kind)
	assert.Equal(t, "first\nsecond\n[image]", res.Entries[0].Text)
}

// Fix round 5 (codex P2): an ordinary message of several blocks is joined
// once. Relative: its entry costs less than two joins more than a one-block
// message of the same text.
func TestUserEntries_OrdinaryBlocksJoinedOnce(t *testing.T) {
	part := strings.Repeat("ordinary words ", 4000)
	var one, many record
	one.Message.Content, _ = json.Marshal([]map[string]any{textBlock(part + "\n" + part)})
	many.Message.Content, _ = json.Marshal([]map[string]any{textBlock(part), textBlock(part)})
	size := func(rec record) float64 {
		var m0, m1 runtime.MemStats
		runtime.ReadMemStats(&m0)
		for range 20 {
			if len(userEntries(rec)) != 1 {
				t.Fatal("one owner entry")
			}
		}
		runtime.ReadMemStats(&m1)
		return float64(m1.TotalAlloc-m0.TotalAlloc) / 20
	}
	joined := float64(2*len(part) + 1)
	assert.Less(t, size(many)-size(one), 1.5*joined, "one join of %v bytes, not three", joined)
}

// Final review F1 (codex #2): two complete notifications read as one text —
// a reminder crossing their blocks, or one plain string holding both — give
// the first notification its own result, as main does; its result does not
// run to the second one's close.
func TestNoticeTask_TwoNoticesInOneTextKeepTheFirstResult(t *testing.T) {
	for name, rec := range map[string]string{
		"reminder crossing blocks": userBlocks("n1",
			textBlock(siblingA+"\n<system-reminder>x"),
			textBlock("</system-reminder>\n"+siblingB),
		),
		"plain string": userStr("n1", siblingA+"\n"+siblingB),
	} {
		res := parseStr(t, rec, 0)
		require.NotEmpty(t, res.Entries, name)
		e := res.Entries[0]
		assert.Equal(t, "n1", e.ID, name)
		require.NotNil(t, e.Task, name)
		assert.Equal(t, "a1", e.Task.TaskID, name)
		assert.Equal(t, "done A", e.Task.Result, name)
		assert.Equal(t, "completed", e.Task.Status, name)
		assert.NotContains(t, e.Text, "b2", name)
	}
}

// Final review (codex #3): a teammate message quoting its own close tag ends
// only at its terminal close; the prose continuing in the next block stays.
func TestNoticeMate_QuotedCloseTagThenProseAcrossBlocks(t *testing.T) {
	res := parseStr(t, userBlocks("n1",
		textBlock(`<teammate-message teammate_id="rev" summary="Tags">`+"\nIt wraps with </teammate-message> tags"),
		textBlock("and goes on here\n</teammate-message>"),
	), 0)
	require.Len(t, res.Entries, 1)
	e := res.Entries[0]
	assert.Equal(t, KindEvent, e.Kind)
	assert.Equal(t, EventTeammate, e.EventType)
	assert.Contains(t, e.Text, "It wraps with </teammate-message> tags")
	assert.Contains(t, e.Text, "and goes on here")
}
