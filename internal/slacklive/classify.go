// Package slacklive probes whether the owner's Claude or Codex account can
// read Slack through its own connector (Slack Live), and classifies the
// outcome into the slack_live_status vocabulary.
package slacklive

import "strings"

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

// ReadTools is the Slack connector's read-only tool allow-list (bare names).
// Anything outside it is never called by a Live path.
var ReadTools = []string{
	"slack_search_public",
	"slack_search_public_and_private",
	"slack_search_channels",
	"slack_search_users",
	"slack_read_channel",
	"slack_read_thread",
	"slack_read_canvas",
	"slack_read_user_profile",
	"slack_list_user_channels",
	"slack_list_channel_members",
	"slack_get_reactions",
	"slack_read_file",
	"slack_list_workspaces",
}

// Classify maps a probe's evidence to (status, error_class). text is the
// concatenated tool error / stderr / result error text; connected says the
// Slack connector was present; readOK says a real read call succeeded.
func Classify(provider, text string, connected, readOK bool) (status, errorClass string) {
	if connected && readOK {
		return StatusOK, ""
	}
	t := strings.ToLower(text)
	has := func(subs ...string) bool {
		for _, s := range subs {
			if strings.Contains(t, s) {
				return true
			}
		}
		return false
	}
	switch {
	case has(SentinelAPIKeyLogin):
		return StatusNotConnected, "api_key_login"
	case has("admin") && has("approv"):
		return StatusNeedsAdmin, "admin_approval"
	case has("429", "rate limit", "rate_limit", "ratelimit", "too many requests"):
		return StatusUnavailable, "rate_limited"
	case has("timeout", "timed out", "deadline exceeded"):
		return StatusUnavailable, "timeout"
	case has("your plan", "paid plan", "upgrade", "not available on"):
		return StatusNoPlan, "plan"
	case has("unknown tool"):
		return StatusNotConnected, "not_authorized"
	case !connected:
		return StatusNotConnected, "no_connector"
	}
	return StatusUnavailable, "read_failed"
}
