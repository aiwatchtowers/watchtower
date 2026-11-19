package claude

import "testing"

// The precedence is fixed (a key beats a cloud provider, Vertex beats
// Foundry), the last entry of a key wins, an empty last value does not count
// and only the exact name matches.
func TestLoginOverride_OrderAndLastWins(t *testing.T) {
	cases := []struct {
		name string
		env  []string
		kind string
		ok   bool
	}{
		{"nil env", nil, "", false},
		{"api key", []string{"ANTHROPIC_API_KEY=k"}, "api_key", true},
		{"auth token", []string{"ANTHROPIC_AUTH_TOKEN=t"}, "api_key", true},
		{"key beats cloud", []string{"CLAUDE_CODE_USE_BEDROCK=1", "ANTHROPIC_API_KEY=k"}, "api_key", true},
		{"vertex beats foundry", []string{"CLAUDE_CODE_USE_VERTEX=1", "CLAUDE_CODE_USE_FOUNDRY=1"}, "vertex", true},
		{"foundry", []string{"CLAUDE_CODE_USE_FOUNDRY=1"}, "foundry", true},
		{"last wins", []string{"ANTHROPIC_API_KEY=k", "ANTHROPIC_API_KEY="}, "", false},
		{"exact name", []string{"ANTHROPIC_API_KEY_X=k"}, "", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			kind, ok := LoginOverride(c.env)
			if kind != c.kind || ok != c.ok {
				t.Errorf("LoginOverride(%q) = (%q, %v), want (%q, %v)", c.env, kind, ok, c.kind, c.ok)
			}
		})
	}
}
