package providers

import "regexp"

// Codex exec 0.166 emits only ThreadErrorEvent.message (exec_events.rs),
// losing UsageLimitReached's structured reset. Match the documented display
// templates in protocol/src/error.rs, rather than arbitrary mentions of quota.
// Local-time human resets lack a timezone and stay unknown here.
const codexLocalReset = `(?:later|at (?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [1-9][0-9]?(?:st|nd|rd|th), [0-9]{4} )?(?:[1-9]|1[0-2]):[0-5][0-9] (?:AM|PM))`

var codexSubscriptionLimit = regexp.MustCompile(`^You[’']ve hit your usage limit\. (?:Try again ` + codexLocalReset + `\.|` +
	`(?:Visit https://chatgpt\.com/settings/usage to purchase more credits|` +
	`Upgrade to Pro \(https://chatgpt\.com/explore/pro\), visit https://chatgpt\.com/settings/usage to purchase more credits|` +
	`To get more access now, send a request to your admin) or try again ` + codexLocalReset + `\.|` +
	`Upgrade to Plus to continue using Codex \(https://chatgpt\.com/explore/plus\), or try again ` + codexLocalReset + `\.)$`)

// CodexMessageFailure is only for the CLI's own failed terminal envelope.
func CodexMessageFailure(message string, cause error) error {
	if codexSubscriptionLimit.MatchString(message) {
		return &Failure{Provider: "codex", Category: Quota, Scope: "installation", Cause: cause}
	}
	return TerminalFailure("codex", FailureDetail{Message: message}, 0, cause)
}
