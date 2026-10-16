package sessionfeed

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func writeConv(t *testing.T, dir, id, body string) Conversation {
	t.Helper()
	p := filepath.Join(dir, id+".jsonl")
	require.NoError(t, os.WriteFile(p, []byte(body), 0o600))
	return Conversation{AgentSessionID: id, Path: p}
}

func TestBuild_TwoConversationsWithSeparator(t *testing.T) {
	dir := t.TempDir()
	a := writeConv(t, dir, "A", join(userStr("u1", "one"), assistantRec("a1", "m1", textB("two"))))
	b := writeConv(t, dir, "B", userStr("u2", "three"))
	f, err := Build([]Conversation{a, b}, nil, nil)
	require.NoError(t, err)
	require.Len(t, f.Entries, 4)
	assert.Equal(t, KindSeparator, f.Entries[2].Kind)
	assert.Equal(t, "B:sep", f.Entries[2].ID)
	assert.Equal(t, "three", f.Entries[3].Text)
	assert.Equal(t, "B", f.Cursor.Conv)
	assert.Equal(t, int64(len(userStr("u2", "three"))), f.Cursor.Offset)
}

func TestBuild_MissingFileSkipped(t *testing.T) {
	dir := t.TempDir()
	b := writeConv(t, dir, "B", userStr("u2", "x"))
	f, err := Build([]Conversation{{AgentSessionID: "A", Path: filepath.Join(dir, "gone.jsonl")}, b}, nil, nil)
	require.NoError(t, err)
	require.Len(t, f.Entries, 1)
	assert.Equal(t, "x", f.Entries[0].Text)
}

func TestBuild_AfterCursor(t *testing.T) {
	dir := t.TempDir()
	l1 := userStr("u1", "one")
	l2 := assistantRec("a1", "m1", textB("He"))
	a := writeConv(t, dir, "A", l1+l2)
	f1, err := Build([]Conversation{a}, nil, nil)
	require.NoError(t, err)
	// the file grows: the streamed message continues, a new owner line arrives
	a = writeConv(t, dir, "A", l1+l2+assistantRec("a2", "m1", textB("Hello"))+userStr("u2", "next"))
	f2, err := Build([]Conversation{a}, &f1.Cursor, nil)
	require.NoError(t, err)
	require.Len(t, f2.Entries, 2)
	assert.Equal(t, "m1", f2.Entries[0].ID)
	assert.Equal(t, "Hello", f2.Entries[0].Text)
	assert.Equal(t, "next", f2.Entries[1].Text)
	// an unchanged feed re-emits nothing
	f3, err := Build([]Conversation{a}, &f2.Cursor, nil)
	require.NoError(t, err)
	assert.Empty(t, f3.Entries)
	assert.Equal(t, f2.Cursor, f3.Cursor)
}

func TestBuild_AfterCursorSkipsEarlierConversations(t *testing.T) {
	dir := t.TempDir()
	a := writeConv(t, dir, "A", userStr("u1", "one"))
	b := writeConv(t, dir, "B", userStr("u2", "two"))
	f1, err := Build([]Conversation{a}, nil, nil)
	require.NoError(t, err)
	f2, err := Build([]Conversation{a, b}, &f1.Cursor, nil)
	require.NoError(t, err)
	require.Len(t, f2.Entries, 2)
	assert.Equal(t, "B:sep", f2.Entries[0].ID)
	assert.Equal(t, "two", f2.Entries[1].Text)
}

func TestBuild_SubagentsAlwaysListed(t *testing.T) {
	dir := t.TempDir()
	a := writeConv(t, dir, "A", join(userStr("u1", "go"),
		assistantRec("a1", "m1", agentCall("tu1", "Explore", "look")),
		userStr("u2", "later")))
	writeSub(t, filepath.Join(dir, "A"), "ag1", `{"toolUseId":"tu1","finished":true}`, "")
	cur := Cursor{Conv: "A", Offset: int64(len(userStr("u1", "go")) + len(assistantRec("a1", "m1", agentCall("tu1", "Explore", "look"))))}
	f, err := Build([]Conversation{a}, &cur, nil)
	require.NoError(t, err)
	require.Len(t, f.Entries, 1)
	assert.Equal(t, "later", f.Entries[0].Text)
	require.Len(t, f.Subagents, 1)
	assert.Equal(t, StatusFinished, f.Subagents[0].Subagent.Status)
	assert.Equal(t, "ag1", f.Subagents[0].Subagent.AgentID)
}

func TestBuild_AskLookup(t *testing.T) {
	dir := t.TempDir()
	a := writeConv(t, dir, "A", join(userStr("u1", askLine(7)), userStr("u2", askLine(8))))
	look := func(id int64) (string, string, bool) {
		if id == 7 {
			return "Pick one", "Answer: yes", true
		}
		return "", "", false
	}
	f, err := Build([]Conversation{a}, nil, look)
	require.NoError(t, err)
	require.Len(t, f.Entries, 2)
	assert.Equal(t, KindAskAnswer, f.Entries[0].Kind)
	assert.Equal(t, "Answer: yes", f.Entries[0].Text)
	assert.Equal(t, "Pick one", f.Entries[0].Title)
	assert.Equal(t, KindAskAnswer, f.Entries[1].Kind)
	assert.Equal(t, askLine(8), f.Entries[1].Text)
	assert.Empty(t, f.Entries[1].Title)
}

func TestCursor_RoundTrip(t *testing.T) {
	c, err := ParseCursor(Cursor{Conv: "a:b", Offset: 42}.String())
	require.NoError(t, err)
	assert.Equal(t, Cursor{Conv: "a:b", Offset: 42}, c)
}

func TestParseCursor_Rejects(t *testing.T) {
	for _, s := range []string{"", "x", "a:-1", ":5", "a:x"} {
		_, err := ParseCursor(s)
		assert.Error(t, err, s)
	}
}

func TestLocateAll_FindsInCandidateDirs(t *testing.T) {
	proj := t.TempDir()
	slugDir := filepath.Join(proj, "-w-app")
	require.NoError(t, os.MkdirAll(filepath.Join(slugDir, "u1", "subagents"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(slugDir, "u1.jsonl"), []byte("x\n"), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(slugDir, "u2.jsonl"), []byte("x\n"), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(slugDir, "u1", "subagents", "agent-z.jsonl"), []byte("x\n"), 0o600))
	// "z" is a subagent id, not a session; "nope" has no transcript.
	got := LocateAll(proj, []string{"/w/app"}, []string{"u1", "u2", "nope", "z"})
	assert.Equal(t, map[string]string{
		"u1": filepath.Join(slugDir, "u1.jsonl"),
		"u2": filepath.Join(slugDir, "u2.jsonl"),
	}, got)
}

func TestBuild_AfterCursorReadsOnlyTail(t *testing.T) {
	dir := t.TempDir()
	head := userStr("u1", "one")
	b := writeConv(t, dir, "B", head+userStr("u2", "two"))
	cur := Cursor{Conv: "B", Offset: int64(len(head))}
	// the bytes before the cursor and the whole earlier conversation are unreadable
	require.NoError(t, os.WriteFile(b.Path, []byte(repeat("x", len(head))+userStr("u2", "two")), 0o600))
	a := Conversation{AgentSessionID: "A", Path: filepath.Join(dir, "A.jsonl")}
	require.NoError(t, os.WriteFile(a.Path, []byte("not json\n"), 0o600))
	f, err := Build([]Conversation{a, b}, &cur, nil)
	require.NoError(t, err)
	require.Len(t, f.Entries, 1)
	assert.Equal(t, "two", f.Entries[0].Text)
	assert.Zero(t, f.Skipped)
	assert.Empty(t, f.Unknown)
}

func TestBuild_SubagentsFromMetaOnly(t *testing.T) {
	dir := t.TempDir()
	head := join(userStr("u1", "go"), assistantRec("a1", "m1", agentCall("tu1", "Explore", "look")))
	a := writeConv(t, dir, "A", repeat("x", len(head))+userStr("u2", "later")) // head is garbage: never parsed
	writeSub(t, filepath.Join(dir, "A"), "ag1",
		`{"toolUseId":"tu1","finished":false,"agentType":"Explore","description":"look"}`, "")
	f, err := Build([]Conversation{a}, &Cursor{Conv: "A", Offset: int64(len(head))}, nil)
	require.NoError(t, err)
	require.Len(t, f.Subagents, 1)
	ref := f.Subagents[0].Subagent
	assert.Equal(t, "tu1", f.Subagents[0].ID)
	assert.Equal(t, StatusRunning, ref.Status)
	assert.Equal(t, "ag1", ref.AgentID)
	assert.Equal(t, "Explore", ref.Type)
	assert.Equal(t, "look", ref.Description)
}

// BEHAVIOR FEED-01: the reader only reads transcripts.
func TestFeed01_ReaderLeavesTranscriptUntouched(t *testing.T) {
	dir := t.TempDir()
	c := writeConv(t, dir, "A", join(userStr("u1", "one"), assistantRec("a1", "m1", textB("two"))))
	old := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	require.NoError(t, os.Chtimes(c.Path, old, old))
	before, err := os.Stat(c.Path)
	require.NoError(t, err)

	f, err := Build([]Conversation{c}, nil, nil)
	require.NoError(t, err)
	require.Len(t, f.Entries, 2)
	_, err = Build([]Conversation{c}, &f.Cursor, nil)
	require.NoError(t, err)

	after, err := os.Stat(c.Path)
	require.NoError(t, err)
	assert.Equal(t, before.Size(), after.Size())
	assert.True(t, before.ModTime().Equal(after.ModTime()), "mtime changed")
	entries, err := os.ReadDir(dir)
	require.NoError(t, err)
	assert.Len(t, entries, 1, "reader must create no sibling files")
}
