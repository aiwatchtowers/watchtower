package sessionfeed

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

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

// Fix round 4 (codex P2): a user record's content is decoded once, tool
// results included. Relative: reading a record of many tool results allocates
// less than two decodes of its content would.
func TestUserEntries_DecodesContentOnce(t *testing.T) {
	var sb strings.Builder
	sb.WriteByte('[')
	for i := range 300 {
		if i > 0 {
			sb.WriteByte(',')
		}
		fmt.Fprintf(&sb, `{"type":"tool_result","tool_use_id":"t%d","content":"out %d"}`, i, i)
	}
	sb.WriteByte(']')
	var rec record
	rec.UUID = "u1"
	rec.Message.Content = json.RawMessage(sb.String())
	once := testing.AllocsPerRun(20, func() {
		var bs []block
		_ = json.Unmarshal(rec.Message.Content, &bs)
	})
	got := testing.AllocsPerRun(20, func() {
		if len(userEntries(rec)) != 0 {
			t.Fatal("a tool-result record gives no entry")
		}
	})
	assert.Less(t, got, once*1.5, "one decode of the content, not two (one decode = %v allocations)", once)
}

// Notices beside an image stay one entry, the leading notice read in its block.
func TestNoticeTask_NoticesBesideAnImageStayOneEntry(t *testing.T) {
	res := parseStr(t, userBlocks("n1", textBlock(siblingA), textBlock(siblingB), map[string]any{"type": "image"}), 0)
	require.Len(t, res.Entries, 1)
	assert.Equal(t, "n1", res.Entries[0].ID)
	require.NotNil(t, res.Entries[0].Task)
	assert.Equal(t, "done A", res.Entries[0].Task.Result)
}
