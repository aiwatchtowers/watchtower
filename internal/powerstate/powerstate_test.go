package powerstate

import (
	"errors"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestFullWakeFrom(t *testing.T) {
	cases := []struct {
		name string
		caps uint32
		want bool
	}{
		{"full wake: cpu disk net aud vid", 0x1f, true},
		{"full wake: cpu vid", 0x03, true},
		{"full wake with background bit", 0x5f, true},
		{"dark wake: cpu disk net aud", 0x1d, false},
		{"dark wake: cpu disk net", 0x19, false},
		{"dark wake: cpu only", 0x01, false},
		{"no cpu bit: zero reads as awake", 0x00, true},
		{"no cpu bit: vid only reads as awake", 0x02, true},
		{"no cpu bit: everything else reads as awake", 0x1e, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			assert.Equal(t, tc.want, fullWakeFrom(tc.caps))
		})
	}
}

func TestFullWake_NoReaderIsAwake(t *testing.T) {
	t.Cleanup(SetReaderForTesting(nil))
	assert.True(t, FullWake())
}

func TestFullWake_ReadErrorIsAwake(t *testing.T) {
	t.Cleanup(SetReaderForTesting(func() (uint32, error) {
		return capCPU, errors.New("read failed") // a dark-wake value, but an error
	}))
	assert.True(t, FullWake())
}

func TestFullWake_UsesReader(t *testing.T) {
	t.Cleanup(SetReaderForTesting(func() (uint32, error) { return 0x1d, nil }))
	assert.False(t, FullWake())

	inner := SetReaderForTesting(func() (uint32, error) { return 0x1f, nil })
	assert.True(t, FullWake())
	inner()
	assert.False(t, FullWake(), "restore puts the previous reader back")
}
