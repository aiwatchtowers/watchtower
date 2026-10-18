package sessionfeed

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func readFixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "codex", name))
	require.NoError(t, err)
	return b
}

func TestParseCodex_OwnerAgentBriefAskAnswer(t *testing.T) {
	raw := readFixture(t, "mixed.jsonl")
	res, err := ParseCodex(bytes.NewReader(raw), 0, "conv")
	require.NoError(t, err)
	require.Len(t, res.Entries, 6)
	kinds := []Kind{KindBrief, KindOwner, KindAgent, KindAskAnswer, KindOwner, KindAgent}
	for i, e := range res.Entries {
		assert.Equal(t, kinds[i], e.Kind, "entry %d", i)
		assert.Equal(t, "conv", e.Conversation)
	}
	assert.Equal(t, "u2", res.Entries[1].ID)
	assert.Equal(t, "please add a flag", res.Entries[1].Text)
	assert.Equal(t, "done, flag added", res.Entries[2].Text)
	assert.EqualValues(t, 12, res.Entries[3].AskID)
	assert.Equal(t, "legacy owner line", res.Entries[4].Text)
	assert.Equal(t, "legacy agent line", res.Entries[5].Text)
	assert.True(t, strings.HasPrefix(res.Entries[4].ID, "L"))
	assert.Equal(t, time.Date(2026, 10, 12, 12, 0, 3, 0, time.UTC), res.Entries[1].At)
	assert.EqualValues(t, len(raw), res.Offset)
}

func TestParseCodex_SkipsZstd(t *testing.T) {
	res, err := ParseCodex(bytes.NewReader(append([]byte{0x28, 0xb5, 0x2f, 0xfd}, "binary\n"...)), 0, "c")
	require.NoError(t, err)
	assert.Empty(t, res.Entries)
	assert.Equal(t, 1, res.Unknown["<zstd>"])
}

func TestParseCodex_OffsetResume(t *testing.T) {
	raw := readFixture(t, "mixed.jsonl")
	first, err := ParseCodex(bytes.NewReader(raw), 0, "c")
	require.NoError(t, err)
	// cut after the second line holding an entry, mid-way into the next line
	cut := bytes.Index(raw, []byte("please add a flag"))
	cut += bytes.IndexByte(raw[cut:], '\n') + 1
	half := cut + 10
	part, err := ParseCodex(bytes.NewReader(raw[:half]), 0, "c")
	require.NoError(t, err)
	assert.EqualValues(t, cut, part.Offset, "partial last line is left for the next call")
	rest, err := ParseCodex(bytes.NewReader(raw[part.Offset:]), part.Offset, "c")
	require.NoError(t, err)
	assert.Equal(t, first.Entries, append(part.Entries, rest.Entries...))
	assert.EqualValues(t, len(raw), rest.Offset)
}

func TestFeed01_CodexReaderLeavesTranscriptUntouched(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "rollout-x.jsonl")
	require.NoError(t, os.WriteFile(p, readFixture(t, "mixed.jsonl"), 0o600))
	old := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	require.NoError(t, os.Chtimes(p, old, old))
	before, err := os.Stat(p)
	require.NoError(t, err)

	f, err := Build([]Conversation{{AgentSessionID: "A", Path: p, Codex: true}}, nil, nil)
	require.NoError(t, err)
	require.Len(t, f.Entries, 6)

	after, err := os.Stat(p)
	require.NoError(t, err)
	assert.Equal(t, before.Size(), after.Size())
	assert.True(t, before.ModTime().Equal(after.ModTime()), "mtime changed")
	entries, err := os.ReadDir(dir)
	require.NoError(t, err)
	assert.Len(t, entries, 1, "reader must create no sibling files")
}

func TestLocateCodex(t *testing.T) {
	home := t.TempDir()
	id := "01a10000-0000-7000-8000-000000000101"
	day := filepath.Join(home, "sessions", "2026", "10", "12")
	require.NoError(t, os.MkdirAll(day, 0o755))
	p := filepath.Join(day, "rollout-2026-10-12T12-00-00-"+id+".jsonl")
	require.NoError(t, os.WriteFile(p, []byte("{}\n"), 0o600))
	resolved, _ := filepath.EvalSymlinks(p)

	got, ok := LocateCodex(home, id, "")
	assert.True(t, ok)
	assert.Equal(t, resolved, got)
	got, ok = LocateCodex("", id, p)
	assert.True(t, ok)
	assert.Equal(t, p, got)
	_, ok = LocateCodex(home, "01a10000-0000-7000-8000-0000000009ff", "")
	assert.False(t, ok)
	_, ok = LocateCodex(home, "../etc", "")
	assert.False(t, ok)
}
