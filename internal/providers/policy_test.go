package providers

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
)

func TestProviderPolicy_Allowed(t *testing.T) {
	policytest.Set(t, nil)
	assert.NoError(t, Allowed("codex"))

	policytest.Set(t, map[string]any{"AllowedAIProviders": []any{"claude"}})
	assert.NoError(t, Allowed(""), "the empty provider is claude")
	assert.NoError(t, Allowed("claude"))
	err := Allowed("codex")
	require.ErrorIs(t, err, policy.ErrNotAllowed)
	assert.Equal(t, "policy: AI provider codex is not allowed by your organization (allowed: claude)", err.Error())
	require.ErrorIs(t, Allowed("ollama"), policy.ErrNotAllowed)
}
