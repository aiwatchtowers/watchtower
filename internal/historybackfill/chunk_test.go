package historybackfill

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestNextChunk(t *testing.T) {
	day := 86400.0
	from, to, ok := NextChunk(10*day, 0)
	assert.True(t, ok)
	assert.Equal(t, 8*day, from)
	assert.Equal(t, 10*day, to)
	from, to, ok = NextChunk(day, 0)
	assert.True(t, ok)
	assert.Equal(t, 0.0, from)
	assert.Equal(t, day, to) // clamped to the floor
	_, _, ok = NextChunk(0, 0)
	assert.False(t, ok)
}
