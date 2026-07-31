package calendar

import (
	"html"
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
		// HTML descriptions carry entity-encoded URLs (`&amp;` inside an
		// href) and NBSP separators — raw U+00A0 or `&nbsp;` — that Go's
		// ASCII-only `\s` would absorb into the match, breaking the link.
		// Decode entities first (`&amp;`→`&` stays in the URL; `&lt;`/`&gt;`/
		// `&quot;` decode to characters the pattern already excludes), then
		// turn NBSP into a plain space so it bounds the URL.
		text = strings.ReplaceAll(html.UnescapeString(text), "\u00a0", " ")
		if m := conferenceURLPattern.FindString(text); m != "" {
			// A link at the end of a sentence drags trailing punctuation
			// into the match — trim it so the URL opens cleanly.
			return strings.TrimRight(m, ".,;:!?)")
		}
	}
	return ""
}
