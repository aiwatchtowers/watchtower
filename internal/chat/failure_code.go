package chat

import (
	"errors"

	"watchtower/internal/logredact"
	"watchtower/internal/providers"
)

// failureCode is one row of the category → chat-code table.
type failureCode struct {
	code      string
	retryable bool
}

// failureCodes is the one mapping from a typed provider failure to the
// protocol's error code (spec 2026-11-05 §3.1 item 5). Every providers
// category has a row (TestCodeForFailure_EveryCategory).
var failureCodes = map[providers.ErrorCategory]failureCode{
	providers.Quota:         {CodeRateLimit, false},
	providers.RateLimit:     {CodeRateLimit, true},
	providers.Overload:      {CodeRateLimit, true},
	providers.Auth:          {CodeAuth, false},
	providers.Policy:        {CodeAuth, false},
	providers.Model:         {CodeProviderUnavailable, false},
	providers.ContextLimit:  {CodeInternal, false},
	providers.Budget:        {CodeInternal, false},
	providers.Cancelled:     {CodeInterrupted, false},
	providers.Timeout:       {CodeProviderUnavailable, true},
	providers.Transport:     {CodeProviderUnavailable, true},
	providers.InvalidOutput: {CodeInternal, true},
	providers.Capability:    {CodeInternal, false},
	providers.Unknown:       {CodeInternal, true},
}

// CodeForFailure is the chat error code of a provider failure category and
// whether a retry can help. A category without a row is internal, retryable.
func CodeForFailure(category providers.ErrorCategory) (code string, retryable bool) {
	if row, ok := failureCodes[category]; ok {
		return row.code, row.retryable
	}
	return CodeInternal, true
}

// ClassifyFailure is a failed turn's code, routing reason and retry hint:
// a typed *providers.Failure decides through CodeForFailure (its text is
// never read), and only an untyped error — or one typed Unknown — falls back
// to ClassifyClaudeError's text matching. The reason is "quota_exhausted"
// for a spent subscription and "required_capability_missing" for a refused
// capability, "" otherwise.
func ClassifyFailure(err error) (code, reason string, retryable bool) {
	var failure *providers.Failure
	if !errors.As(err, &failure) || failure.Category == providers.Unknown {
		code, retryable = ClassifyClaudeError(logredact.Full(err))
		return code, "", retryable
	}
	code, retryable = CodeForFailure(failure.Category)
	if failure.Category == providers.Quota {
		reason = "quota_exhausted"
	} else if failure.Category == providers.Capability {
		reason = "required_capability_missing"
	}
	return code, reason, retryable
}
