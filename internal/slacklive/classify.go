// Package slacklive probes whether the owner's Claude or Codex account can
// read Slack through its own connector (Slack Live), and classifies the
// outcome into the slack_live_status vocabulary.
package slacklive

import (
	"strings"

	"watchtower/internal/slackconnector"
)

// Statuses of slack_live_status.
const (
	StatusOK           = "ok"
	StatusNotConnected = "not_connected"
	StatusNeedsAdmin   = "needs_admin"
	StatusNoPlan       = "no_plan"
	StatusUnavailable  = "unavailable"
)

// SentinelAPIKeyLogin is the text a probe hands Classify when the provider
// runs on an API key, which never has the account's connectors.
const SentinelAPIKeyLogin = "api_key_login"

// ReadTools is the Slack connector's read-only tool allow-list (bare
// names), slackconnector's one list. Anything outside it is never called by
// a Live path.
var ReadTools = slackconnector.ReadTools

// ClaudeStepPrefix and CodexStepPrefix are a connector tool's step name in
// the chat (slackconnector).
const (
	ClaudeStepPrefix = slackconnector.ClaudeStepPrefix
	CodexStepPrefix  = slackconnector.CodexStepPrefix
)

// Classify maps a probe's evidence to (status, error_class). text is the
// concatenated tool error / stderr / result error text; connected says the
// Slack connector was present; readOK says a real read call succeeded.
func Classify(text string, connected, readOK bool) (status, errorClass string) {
	return classify(text, "", connected, readOK)
}

// classify is Classify with the evidence split: toolText is what the tool
// call or the run's result reported, stderr is the child's raw stderr. Plan
// and unknown-tool wording is matched in toolText only, since a CLI's stderr
// is noisy and mentions plans and upgrades for unrelated reasons.
func classify(toolText, stderr string, connected, readOK bool) (status, errorClass string) {
	if connected && readOK {
		return StatusOK, ""
	}
	tool := strings.ToLower(toolText)
	all := tool + " " + strings.ToLower(stderr)
	has := func(t string, subs ...string) bool {
		for _, s := range subs {
			if strings.Contains(t, s) {
				return true
			}
		}
		return false
	}
	switch {
	case has(all, SentinelAPIKeyLogin):
		return StatusNotConnected, "api_key_login"
	case has(all, "admin") && has(all, "approv"):
		return StatusNeedsAdmin, "admin_approval"
	case has(all, "429", "rate limit", "rate_limit", "ratelimit", "too many requests"):
		return StatusUnavailable, "rate_limited"
	case has(all, "timeout", "timed out", "deadline exceeded"):
		return StatusUnavailable, ErrorClassTimeout
	case has(tool, "not available on your plan", "your plan does not", "paid plan",
		"upgrade your plan", "upgrade to a"):
		return StatusNoPlan, "plan"
	case has(tool, "unknown tool"):
		return StatusNotConnected, "not_authorized"
	case !connected:
		return StatusNotConnected, "no_connector"
	}
	return StatusUnavailable, ErrorClassReadFailed
}

// ErrorClassReadFailed is an ordinary tool error (a missing channel, bad
// arguments): it says nothing about the connection.
const ErrorClassReadFailed = "read_failed"

// ErrorClassTimeout is a call that timed out.
const ErrorClassTimeout = "timeout"

// ConnectionVerdict reports whether a connector call's (status, class) says
// something about the connection — ok, or a connection-class failure
// (not connected, admin approval, plan, rate limit) — and so may be written
// as the provider's Live status. An ordinary tool error may not: a failed
// read (ErrorClassReadFailed) or one call's timeout (ErrorClassTimeout)
// must not turn Live off. The probe still records its own timeout.
func ConnectionVerdict(status, errorClass string) bool {
	return !(status == StatusUnavailable && (errorClass == ErrorClassReadFailed || errorClass == ErrorClassTimeout))
}
