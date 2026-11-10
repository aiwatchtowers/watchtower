package reviewai

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestParseChapters_DropsForeignEntriesOneByOne(t *testing.T) {
	raw := `{"chapters":[
	 {"key":"dir:server","what":"Endpoint.","risks":[{"path":"server/greet.go","level":"high","why":"x"},{"path":"pkg/other.go","level":"high","why":"foreign path"}]},
	 {"key":"lane:elsewhere","what":"foreign key","risks":[]},
	 {"key":"dir:scripts","what":"Script.","risks":[{"path":"scripts/cleanup.sh","level":"severe","why":"bad enum"}]}]}`
	descs, err := ParseChapters(raw, okBatch(t))
	require.NoError(t, err)
	assert.Equal(t, map[string]ChapterDesc{
		"dir:server":  {Key: "dir:server", What: "Endpoint.", Risks: []Risk{{Path: "server/greet.go", Level: "high", Why: "x"}}},
		"dir:scripts": {Key: "dir:scripts", What: "Script.", Risks: []Risk{}},
	}, descs)
}

func TestParseChapters_NoneOfTheBatchIsParse(t *testing.T) {
	for name, raw := range map[string]string{
		"foreign keys only": `{"chapters":[{"key":"lane:elsewhere","what":"w"}]}`,
		"empty":             `{"chapters":[]}`,
		"not json":          "no",
	} {
		_, err := ParseChapters(raw, okBatch(t))
		assert.ErrorIs(t, err, ErrParse, name)
	}
}

func TestParseChapters_ClipsWhat(t *testing.T) {
	long := make([]rune, 700)
	for i := range long {
		long[i] = 'ж'
	}
	descs, err := ParseChapters(`{"chapters":[{"key":"dir:server","what":"`+string(long)+`"}]}`, okBatch(t))
	require.NoError(t, err)
	assert.Len(t, []rune(descs["dir:server"].What), maxWhatRunes)
}

func TestBuildChaptersUser_NotesOnBatchFilesOnly(t *testing.T) {
	out := BuildChaptersUser(okBatch(t), []db.ReviewNote{
		{Kind: "note", Path: "server/greet.go", StartLine: 1, EndLine: 2, Text: "look here"},
		{Kind: "note", Path: "elsewhere.go", StartLine: 1, EndLine: 1, Text: "not this batch"},
		{Kind: "chapter", Text: "Greeting", Paths: []string{"server/greet.go"}},
	})
	assert.Contains(t, out, "server/greet.go:1-2: look here\n")
	assert.NotContains(t, out, "not this batch")
	assert.Contains(t, out, "--- server/greet.go (modified, +3 −0) [chapter dir:server]\n")
	assert.NotContains(t, out, "=== INTENT ===")
}
