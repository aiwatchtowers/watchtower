package providers

import (
	"errors"
	"regexp"
	"strings"
)

// InvocationProfile is an explicit execution boundary, never inferred from
// missing tool events. ToolPreflight permits selection only before child start.
type InvocationProfile string

const (
	BatchText      InvocationProfile = "batch_text"
	Image          InvocationProfile = "image"
	ReviewReadonly InvocationProfile = "review_readonly"
	ToolPreflight  InvocationProfile = "tool_preflight"
)

// ClaudeNoToolsArgs retains OAuth/keychain and custom transport configuration.
// --bare and replacement config homes would break subscription authentication.
func ClaudeNoToolsArgs() []string {
	return []string{"--strict-mcp-config", "--disable-slash-commands", "--settings", `{"disableAllHooks":true}`}
}

// ReplaySafe reports which profiles permit a fresh physical attempt. Readonly
// reviews stay outside fallback; tool-bearing turns are unsafe once started,
// even when no tool event or text has reached the UI.
func (p InvocationProfile) ReplaySafe() bool { return p == BatchText || p == Image }

// CapabilityError rejects a requested profile before starting a child.
func CapabilityError(provider string, profile InvocationProfile, cause error) error {
	return &Failure{Provider: provider, Category: Capability, Required: profile, Cause: cause}
}

// ProfileStartupFailure recognizes a CLI refusing required isolation switches.
// The refusal stays a capability error; it cannot be treated as subscription
// exhaustion or repaired by dropping the switch and retrying a model call.
func ProfileStartupFailure(provider string, profile InvocationProfile, stderr string, cause error) error {
	var failure *Failure
	if errors.As(cause, &failure) && failure.Category != Unknown {
		return cause
	}
	if unsupportedProfileFlag.MatchString(strings.TrimSpace(stderr)) {
		return CapabilityError(provider, profile, cause)
	}
	return cause
}

var unsupportedProfileFlag = regexp.MustCompile(`(?m)^(?:error: )?(?:unexpected argument|unknown option) ['"](?:--strict-mcp-config|--disable-slash-commands|--settings|--tools|--ephemeral)['"]`)
