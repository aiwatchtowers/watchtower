package calendar

import (
	"regexp"
	"strings"
)

// conferenceURLPattern recognizes meeting links of the well-known conference
// hosts anywhere in free text: Google Meet, Zoom (personal /my/ and scheduled
// /j/ links on any *.zoom.us subdomain), Microsoft Teams, and Webex. The
// pattern matches the URL itself, not surrounding markup, so HTML descriptions
// (where the link appears inside an href attribute) work as-is.
var conferenceURLPattern = regexp.MustCompile(
	`https://(?:` +
		`meet\.google\.com/[^\s"'<>]+` +
		`|(?:[A-Za-z0-9-]+\.)*zoom\.us/(?:j|my)/[^\s"'<>]+` +
		`|teams\.microsoft\.com/[^\s"'<>]+` +
		`|teams\.live\.com/[^\s"'<>]+` +
		`|(?:[A-Za-z0-9-]+\.)*webex\.com/[^\s"'<>]+` +
		`)`)

// ExtractConferenceURL scans the given text fragments (typically an event's
// location and description, in that order) for a conference link. The first
// match wins; "" is returned when nothing matches. Shared by the Google event
// converter (as the fallback after hangoutLink/conferenceData) and the
// CalDAV/ICS sync path, where a pasted Zoom/Meet link in the location or
// description is the only signal available.
func ExtractConferenceURL(texts ...string) string {
	for _, text := range texts {
		if text == "" {
			continue
		}
		if m := conferenceURLPattern.FindString(text); m != "" {
			// A link at the end of a sentence drags trailing punctuation
			// into the match — trim it so the URL opens cleanly.
			return strings.TrimRight(m, ".,;:!?)")
		}
	}
	return ""
}
