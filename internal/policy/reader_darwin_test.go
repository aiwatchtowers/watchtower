//go:build darwin && cgo

package policy

import (
	"crypto/rand"
	"encoding/hex"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestPolicy01_UnforcedValueIgnored pins that a value written the way
// `defaults write` writes it (user layer, not forced) is never policy. It
// uses a throw-away domain, never the app's own, and a per-run key so
// parallel runs never collide; the key is removed again (cfprefsd may keep
// the one empty plist of the domain).
func TestPolicy01_UnforcedValueIgnored(t *testing.T) {
	b := make([]byte, 8)
	_, err := rand.Read(b)
	require.NoError(t, err)
	const domain = "com.watchtower.policytest"
	key := KeyAllowedSources + hex.EncodeToString(b)
	t.Cleanup(func() { setAppValue(domain, key, nil) })

	setAppValue(domain, key, []any{"slack"})
	require.Equal(t, []any{"slack"}, copyAppValue(domain, key), "the user value was written")

	assert.Empty(t, readForced(domain, []string{key}))
}

// TestPolicy_TestBinaryNeverReadsRealPreferences pins that the CoreFoundation
// reader is not installed in a test binary.
func TestPolicy_TestBinaryNeverReadsRealPreferences(t *testing.T) {
	assert.Empty(t, reader())
}

func TestPolicy_ConvertTypes(t *testing.T) {
	assert.Equal(t, true, roundTripCF(true))
	assert.Equal(t, false, roundTripCF(false))
	assert.Equal(t, int64(1), roundTripCF(int64(1)), "the number 1 is a number, not a boolean")
	assert.Equal(t, 2.5, roundTripCF(2.5))
	assert.Equal(t, "", roundTripCF(""))
	assert.Equal(t, "https://mcp.example.com/ü", roundTripCF("https://mcp.example.com/ü"))
	assert.Equal(t, []any{"slack", []any{true, int64(3)}}, roundTripCF([]any{"slack", []any{true, int64(3)}}))
	assert.Equal(t, map[string]any{"messages": int64(1000), "nested": map[string]any{}},
		roundTripCF(map[string]any{"messages": int64(1000), "nested": map[string]any{}}))
	assert.Equal(t, unsupported{}, roundTripCF([]byte("data")))

	p := Normalize(map[string]any{KeyAllowAutomationShell: roundTripCF(int64(1))})
	assert.False(t, p.ShellAllowed(), "an integer 1 from a profile is a wrong type")
	p = Normalize(map[string]any{KeyAllowedSources: roundTripCF([]byte("x"))})
	assert.Equal(t, []string{}, p.Keys.AllowedSources)
}
