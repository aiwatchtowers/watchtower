package reviewai

import (
	"context"
	"database/sql"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/reviewdiff"
)

func TestParseLessons_KeepsGroupsOfTwoOrMoreKnownIDs(t *testing.T) {
	raw := `{"lessons":[
	 {"lens":"tests","text":"Does each change add a test?","source_comment_ids":[1,2,2]},
	 {"lens":"tests","text":"Single?","source_comment_ids":[3]},
	 {"lens":"tests","text":"Unknown id?","source_comment_ids":[1,99]},
	 {"lens":"perf","text":"Does it loop?","source_comment_ids":[1,3]},
	 {"lens":"tests","text":"## Tests","source_comment_ids":[2,3]},
	 {"lens":"tests","text":"- Is it small?\nreally","source_comment_ids":[1,2]},
	 {"lens":"tests","text":"   ","source_comment_ids":[1,2]}]}`
	ls, err := ParseLessons(raw, map[int64]bool{1: true, 2: true, 3: true}, []string{"tests", "house_rules"})
	require.NoError(t, err)
	require.Len(t, ls, 4)
	assert.Equal(t, Lesson{Lens: "tests", Text: "Does each change add a test?", SourceCommentIDs: []int64{1, 2}}, ls[0])
	assert.Equal(t, "house_rules", ls[1].Lens)
	assert.Equal(t, "Tests", ls[2].Text)
	assert.Equal(t, "Is it small? really", ls[3].Text)

	_, err = ParseLessons("not json", nil, nil)
	assert.Error(t, err)
}

func TestParseLessons_CapsAtTwenty(t *testing.T) {
	var b []byte
	b = append(b, `{"lessons":[`...)
	for i := 0; i < 25; i++ {
		if i > 0 {
			b = append(b, ',')
		}
		b = append(b, `{"lens":"x","text":"Q?","source_comment_ids":[1,2]}`...)
	}
	b = append(b, `]}`...)
	ls, err := ParseLessons(string(b), map[int64]bool{1: true, 2: true}, nil)
	require.NoError(t, err)
	assert.Len(t, ls, 20)
}

func TestLessons_BuildsInputAndUsesSourceTag(t *testing.T) {
	g := &recGen{out: `{"lessons":[{"lens":"tests","text":"Does it test?","source_comment_ids":[7,8]}]}`}
	cs := []db.ReviewComment{
		{ID: 7, Path: sql.NullString{String: "a.go", Valid: true}, Lens: "tests", Body: "no test", Quote: "func a()"},
		{ID: 8, Lens: "design", Body: "add a test"},
	}
	ls, err := New(g).Lessons(context.Background(), cs, []reviewdiff.Lens{{ID: "tests"}})
	require.NoError(t, err)
	require.Len(t, ls, 1)
	assert.Equal(t, "workbench.review_lessons", g.source)
	assert.Contains(t, g.user, "#7 [tests] a.go: no test")
	assert.Contains(t, g.user, "quote: func a()")
	assert.Contains(t, g.user, "#8 [design] design: add a test")
}
