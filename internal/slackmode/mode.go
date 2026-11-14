// Package slackmode derives the Slack mode of the app: Full (synced Slack),
// Live (assistant tools only) or Off. Swift twin: SlackMode.swift, both over
// testdata/slack_mode_cases.json.
package slackmode

// Mode is the Slack mode.
type Mode string

const (
	Full Mode = "full"
	Live Mode = "live"
	Off  Mode = "off"
)

// StatusOK is the slack_live_status value of a working Live connection.
const StatusOK = "ok"

// LiveOn reports whether any probe status is ok.
func LiveOn(statuses []string) bool {
	for _, s := range statuses {
		if s == StatusOK {
			return true
		}
	}
	return false
}

// Derive is Full when a synced Slack account exists, else Live when a probe
// is ok, else Off.
func Derive(full bool, live []string) Mode {
	switch {
	case full:
		return Full
	case LiveOn(live):
		return Live
	default:
		return Off
	}
}
