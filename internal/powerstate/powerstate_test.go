package powerstate

import (
	"errors"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestFullWakeFrom(t *testing.T) {
	cases := []struct {
		name string
		caps uint32
		want bool
	}{
		{"full wake: cpu graphics audio network", 0x0f, true},
		{"full wake: cpu graphics", 0x03, true},
		{"full wake with the AOT bit", 0x1f, true},
		{"dark wake: cpu audio network", 0x0d, false},
		{"dark wake: cpu network", 0x09, false},
		{"dark wake: cpu only", 0x01, false},
		{"no cpu bit: zero reads as awake", 0x00, true},
		{"no cpu bit: graphics only reads as awake", 0x02, true},
		{"no cpu bit: everything else reads as awake", 0x0e, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			assert.Equal(t, tc.want, fullWakeFrom(tc.caps))
		})
	}
}

func TestFullWake_NoReaderIsAwake(t *testing.T) {
	t.Cleanup(setReaderForTesting(nil))
	assert.True(t, FullWake())
}

// captureLog swaps logf for a recorder and re-arms the once-per-process
// read-error line for one test.
func captureLog(t *testing.T) *[]string {
	t.Helper()
	var lines []string
	prevLogf, prevLogged := logf, readErrLogged.Load()
	logf = func(format string, args ...any) { lines = append(lines, fmt.Sprintf(format, args...)) }
	readErrLogged.Store(false)
	t.Cleanup(func() { logf = prevLogf; readErrLogged.Store(prevLogged) })
	return &lines
}

func TestFullWake_ReadErrorIsAwake(t *testing.T) {
	captureLog(t)
	t.Cleanup(setReaderForTesting(func() (uint32, error) {
		return capCPU, errors.New("read failed") // a dark-wake value, but an error
	}))
	assert.True(t, FullWake())
}

func TestFullWake_UsesReader(t *testing.T) {
	t.Cleanup(setReaderForTesting(func() (uint32, error) { return 0x0d, nil }))
	assert.False(t, FullWake())

	inner := setReaderForTesting(func() (uint32, error) { return 0x0f, nil })
	assert.True(t, FullWake())
	inner()
	assert.False(t, FullWake(), "restore puts the previous reader back")
}

func TestRead_ReturnsCapsAndVerdict(t *testing.T) {
	t.Cleanup(setReaderForTesting(func() (uint32, error) { return 0x0d, nil }))
	caps, full, err := Read()
	assert.Equal(t, uint32(0x0d), caps)
	assert.False(t, full)
	assert.NoError(t, err)

	caps, full = Probe()
	assert.Equal(t, uint32(0x0d), caps)
	assert.False(t, full)
}

func TestRead_ErrorFailsOpen(t *testing.T) {
	captureLog(t)
	boom := errors.New("read failed")
	t.Cleanup(setReaderForTesting(func() (uint32, error) { return capCPU, boom }))
	caps, full, err := Read()
	assert.Zero(t, caps)
	assert.True(t, full)
	assert.ErrorIs(t, err, boom)
}

func TestRead_NoReader(t *testing.T) {
	t.Cleanup(setReaderForTesting(nil))
	caps, full, err := Read()
	assert.Zero(t, caps)
	assert.True(t, full)
	assert.NoError(t, err)
}

// The first read error is logged once with its reason; later errors and
// successful reads log nothing, and the verdict stays fail-open throughout.
func TestRead_LogsTheFirstErrorOnce(t *testing.T) {
	lines := captureLog(t)
	errs := []error{errors.New("no System Capabilities property"), nil, errors.New("not a 32-bit number"), errors.New("no IOPMrootDomain service")}
	i := 0
	t.Cleanup(setReaderForTesting(func() (uint32, error) {
		err := errs[i]
		i++
		return 0x0f, err
	}))
	for range errs {
		_, full, _ := Read()
		assert.True(t, full)
	}
	assert.Equal(t, []string{"powerstate: cannot read System Capabilities (no System Capabilities property), dark-wake guard off"}, *lines)
}
