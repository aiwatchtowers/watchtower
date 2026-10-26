package automations

import (
	"errors"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/policy"
)

// TestAutomationMCP_PolicyRefusalIsPolicyError: a caller's policy refusal
// (#608) reaches the script as a PolicyError with the policy's message.
func TestAutomationMCP_PolicyRefusalIsPolicyError(t *testing.T) {
	refusal := fmt.Errorf("policy: Quick Connection acme is %w (allowed: none)", policy.ErrNotAllowed)
	err := mcpError(mcpCall{server: "acme", tool: "get"}, refusal)
	var sdk *SDKError
	require.True(t, errors.As(err, &sdk))
	assert.Equal(t, ErrNamePolicy, sdk.Name)
	assert.Equal(t, refusal.Error(), sdk.Message)
}
