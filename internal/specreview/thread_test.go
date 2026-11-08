package specreview

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type threadKeyCase struct {
	WorkbenchID int64  `json:"workbench_id"`
	RootAskID   int64  `json:"root_ask_id"`
	ItemKey     string `json:"item_key"`
	ContextID   string `json:"context_id"`
}

// The Swift twin reads the same fixture: both sides compute one key.
func TestThreadContextID_Fixture(t *testing.T) {
	data, err := os.ReadFile("testdata/thread_keys.json")
	require.NoError(t, err)
	var cases []threadKeyCase
	require.NoError(t, json.Unmarshal(data, &cases))
	require.NotEmpty(t, cases)
	for _, c := range cases {
		assert.Equal(t, c.ContextID, ThreadContextID(c.WorkbenchID, c.RootAskID, c.ItemKey))
		wb, root, key, ok := ParseThreadContextID(c.ContextID)
		require.True(t, ok, c.ContextID)
		assert.Equal(t, c.WorkbenchID, wb)
		assert.Equal(t, c.RootAskID, root)
		assert.Equal(t, c.ItemKey, key)
	}
}

func TestThreadContextID_ParseRefusesMalformed(t *testing.T) {
	for _, s := range []string{"", "1", "1:2", "1:2:", ":2:k", "1::k", "a:2:k", "1:b:k",
		"0:2:k", "1:0:k", "-1:2:k", "+1:2:k", "01:2:k", "1:02:k", "99999999999999999999:2:k"} {
		_, _, _, ok := ParseThreadContextID(s)
		assert.False(t, ok, "%q", s)
	}
}

func TestQuestionTimeout_IsAuthorTimeout(t *testing.T) {
	assert.Equal(t, AuthorTimeout, QuestionTimeout)
}
