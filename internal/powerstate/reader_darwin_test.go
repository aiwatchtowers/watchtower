//go:build darwin && cgo

package powerstate

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The machine running the tests is awake, so the real reader answers with
// the CPU bit set and no error.
func TestReadSystem_ReturnsCPUBit(t *testing.T) {
	caps, err := readSystem()
	require.NoError(t, err)
	assert.NotZero(t, caps&capCPU, "caps=%#x", caps)
}

func TestUseSystemReader_Installs(t *testing.T) {
	t.Cleanup(setReaderForTesting(nil))
	UseSystemReader()
	mu.RLock()
	installed := reader != nil
	mu.RUnlock()
	assert.True(t, installed)
}

func TestReadError_NamesTheReason(t *testing.T) {
	assert.Equal(t, errNoService, readError(codeNoService))
	assert.Equal(t, errNoProperty, readError(codeNoProperty))
	assert.Equal(t, errNotNumber, readError(codeNotNumber))
	assert.EqualError(t, readError(99), "unknown read failure 99")
}
