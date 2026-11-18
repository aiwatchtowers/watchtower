package claude

import "strings"

// loginOverrides are the child environment variables under which the CLI
// does not use the owner's Claude subscription login, in precedence order: an
// API key or token wins over the login, then a third-party cloud provider.
var loginOverrides = []struct{ name, kind string }{
	{"ANTHROPIC_API_KEY", "api_key"},
	{"ANTHROPIC_AUTH_TOKEN", "api_key"},
	{"CLAUDE_CODE_USE_BEDROCK", "bedrock"},
	{"CLAUDE_CODE_USE_VERTEX", "vertex"},
	{"CLAUDE_CODE_USE_FOUNDRY", "foundry"},
}

// LoginOverride reports which non-login authentication the child environment
// env (KEY=VALUE entries, the last one of a key wins, as for exec.Cmd.Env)
// selects: "api_key", "bedrock", "vertex" or "foundry", with ok false when
// the CLI stays on the owner's login. Only whether a value is nonempty is
// looked at; a value is never copied or returned.
func LoginOverride(env []string) (kind string, ok bool) {
	set := make(map[string]bool, len(loginOverrides))
	for _, kv := range env {
		k, v, found := strings.Cut(kv, "=")
		if !found {
			continue
		}
		for _, o := range loginOverrides {
			if o.name == k {
				set[k] = v != ""
				break
			}
		}
	}
	for _, o := range loginOverrides {
		if set[o.name] {
			return o.kind, true
		}
	}
	return "", false
}
