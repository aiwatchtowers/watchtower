package slack

import (
	"fmt"
	"regexp"
	"strings"
)

// GeneratePermalink builds a Slack message permalink URL.
// Format: https://{domain}.slack.com/archives/{channelID}/p{ts_without_dot}
func GeneratePermalink(domain, channelID, ts string) string {
	tsNoDot := strings.ReplaceAll(ts, ".", "")
	return fmt.Sprintf("https://%s.slack.com/archives/%s/p%s", domain, channelID, tsNoDot)
}

// GenerateDeeplink builds a slack:// deep link that opens the Slack app directly.
// For channels: slack://channel?team={teamID}&id={channelID}
// For messages: slack://channel?team={teamID}&id={channelID}&message={ts}
func GenerateDeeplink(teamID, channelID, ts string) string {
	if ts == "" {
		return fmt.Sprintf("slack://channel?team=%s&id=%s", teamID, channelID)
	}
	return fmt.Sprintf("slack://channel?team=%s&id=%s&message=%s", teamID, channelID, ts)
}

// permalinkRe matches Slack web permalinks:
// https://{domain}.slack.com/archives/{channelID}/p{ts_without_dot}
var permalinkRe = regexp.MustCompile(`^https://[^/]+\.slack\.com/archives/([A-Z0-9]+)/p(\d{10})(\d{6})$`)

// PermalinkToDeeplink converts a Slack web permalink to a slack:// deep link.
// Returns the original URL unchanged if it doesn't match the expected format or teamID is empty.
func PermalinkToDeeplink(permalink, teamID string) string {
	if teamID == "" {
		return permalink
	}
	m := permalinkRe.FindStringSubmatch(permalink)
	if m == nil {
		return permalink
	}
	channelID := m[1]
	ts := m[2] + "." + m[3]
	return GenerateDeeplink(teamID, channelID, ts)
}
