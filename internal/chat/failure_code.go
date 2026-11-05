package chat

import (
	"errors"

	"watchtower/internal/logredact"
	"watchtower/internal/providers"
)

// failureCode is one row of the category → chat-code table: the code, the
// routing reason the Desktop persists ("" for none) and whether a retry can
// help.
type failureCode struct {
	code      string
	reason    string
	retryable bool
}

// failureCodes is the one mapping from a typed provider failure to the
// protocol's error code (spec 2026-11-05 §3.1 item 5). Every providers
// category has a row (TestCodeForFailure_EveryCategory). Only Auth means
// "sign in again"; a policy refusal (a 403, a content filter, the
// organization's provider list) is provider_unavailable, as the policy
// gate reports it.
var failureCodes = map[providers.ErrorCategory]failureCode{
	providers.Quota:         {CodeRateLimit, "quota_exhausted", false},
	providers.RateLimit:     {CodeRateLimit, "", true},
	providers.Overload:      {CodeRateLimit, "", true},
	providers.Auth:          {CodeAuth, "", false},
	providers.Policy:        {CodeProviderUnavailable, "", false},
	providers.Model:         {CodeProviderUnavailable, "", false},
	providers.ContextLimit:  {CodeInternal, "", false},
	providers.Budget:        {CodeInternal, "", false},
	providers.Cancelled:     {CodeInterrupted, "", false},
	providers.Timeout:       {CodeProviderUnavailable, "", true},
	providers.Transport:     {CodeProviderUnavailable, "", true},
	providers.InvalidOutput: {CodeInternal, "", true},
	providers.Capability:    {CodeInternal, "required_capability_missing", false},
	providers.Unknown:       {CodeInternal, "", true},
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
// a typed *providers.Failure decides through failureCodes (its text is
// never read), and only an untyped error — or one typed Unknown — falls back
// to ClassifyClaudeError's text matching, with no reason.
func ClassifyFailure(err error) (code, reason string, retryable bool) {
	var failure *providers.Failure
	if !errors.As(err, &failure) || failure.Category == providers.Unknown {
		code, retryable = ClassifyClaudeError(logredact.Full(err))
		return code, "", retryable
	}
	row, ok := failureCodes[failure.Category]
	if !ok {
		return CodeInternal, "", true
	}
	return row.code, row.reason, row.retryable
}
