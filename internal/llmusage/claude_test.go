package llmusage

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestModelFromUsage(t *testing.T) {
	assert.Equal(t, "req", ModelFromUsage(nil, "req"))
	assert.Equal(t, "req", ModelFromUsage(map[string]json.RawMessage{"x": json.RawMessage(`"bad"`)}, "req"))
	tie := map[string]json.RawMessage{
		"claude-b": json.RawMessage(`{"outputTokens":5}`),
		"claude-a": json.RawMessage(`{"outputTokens":5}`),
		"claude-c": json.RawMessage(`{"outputTokens":1}`),
	}
	assert.Equal(t, "claude-a", ModelFromUsage(tie, "req"), "a tie goes to the first name")
}

func TestSplitCacheWrites(t *testing.T) {
	five, one := SplitCacheWrites(700, 0, 200)
	assert.Equal(t, [2]int64{500, 200}, [2]int64{five, one}, "the unsplit rest is 5-minute")
	five, one = SplitCacheWrites(1000, 1000, 0)
	assert.Equal(t, [2]int64{1000, 0}, [2]int64{five, one})
	five, one = SplitCacheWrites(0, 0, 0)
	assert.Equal(t, [2]int64{0, 0}, [2]int64{five, one})
}
