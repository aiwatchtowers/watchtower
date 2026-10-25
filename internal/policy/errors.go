package policy

import (
	"errors"
	"fmt"
	"strings"
)

// ErrNotAllowed is wrapped by every policy refusal.
var ErrNotAllowed = errors.New("not allowed by your organization")

func notAllowed(what, key string) error {
	list := "none"
	if allowed := Current().AllowedList(key); len(allowed) > 0 {
		list = strings.Join(allowed, ", ")
	}
	return fmt.Errorf("policy: %s is %w (allowed: %s)", what, ErrNotAllowed, list)
}

// SourceError is the refusal of a source the policy does not allow.
func SourceError(src string) error { return notAllowed("source "+src, KeyAllowedSources) }

// ProviderError is the refusal of an LLM provider the policy does not allow.
func ProviderError(id string) error { return notAllowed("AI provider "+id, KeyAllowedAIProviders) }

// ConnectionError is the refusal of a Quick Connection the policy does not
// allow.
func ConnectionError(name string) error {
	return notAllowed("Quick Connection "+name, KeyAllowedQuickConnections)
}

// ShellError is the refusal of shell() in an automation.
func ShellError() error {
	return fmt.Errorf("policy: shell() in automations is %w", ErrNotAllowed)
}
