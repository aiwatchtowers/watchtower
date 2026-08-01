package calendar

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestExtractConferenceURL(t *testing.T) {
	cases := []struct {
		name  string
		texts []string
		want  string
	}{
		{
			name:  "google meet in location",
			texts: []string{"https://meet.google.com/abc-defg-hij", ""},
			want:  "https://meet.google.com/abc-defg-hij",
		},
		{
			name:  "zoom scheduled /j/ link with subdomain",
			texts: []string{"", "Join here: https://company.zoom.us/j/1234567890?pwd=abcDEF"},
			want:  "https://company.zoom.us/j/1234567890?pwd=abcDEF",
		},
		{
			name:  "zoom personal /my/ link on bare zoom.us",
			texts: []string{"https://zoom.us/my/vadym"},
			want:  "https://zoom.us/my/vadym",
		},
		{
			name:  "zoom non-meeting link is not a conference URL",
			texts: []string{"https://zoom.us/pricing"},
			want:  "",
		},
		{
			name:  "teams microsoft link",
			texts: []string{"https://teams.microsoft.com/l/meetup-join/19%3ameeting_x?context=%7b%7d"},
			want:  "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x?context=%7b%7d",
		},
		{
			name:  "teams live link",
			texts: []string{"https://teams.live.com/meet/9871234"},
			want:  "https://teams.live.com/meet/9871234",
		},
		{
			name:  "webex link with subdomain",
			texts: []string{"https://acme.webex.com/meet/room123"},
			want:  "https://acme.webex.com/meet/room123",
		},
		{
			name:  "html description href attribute",
			texts: []string{"", `<p>Agenda</p><a href="https://meet.google.com/xyz-abcd-efg">Join</a>`},
			want:  "https://meet.google.com/xyz-abcd-efg",
		},
		{
			// &amp; is the HTML encoding of a literal & — the stored URL must
			// carry the decoded &, or the query string breaks on open.
			name:  "html entity amp in query string decoded",
			texts: []string{"", `<a href="https://company.zoom.us/j/123?pwd=abc&amp;uname=v">Join</a>`},
			want:  "https://company.zoom.us/j/123?pwd=abc&uname=v",
		},
		{
			// &nbsp; decodes to U+00A0, outside Go's ASCII-only \s — it must
			// bound the URL, not be absorbed into it.
			name:  "nbsp entity bounds the url",
			texts: []string{"Join:&nbsp;https://meet.google.com/xyz-abcd-efg&nbsp;(room 5)"},
			want:  "https://meet.google.com/xyz-abcd-efg",
		},
		{
			// Raw U+00A0 (pasted from rich text) would otherwise absorb the
			// following word into the Meet link's path.
			name:  "raw non-breaking space bounds the url",
			texts: []string{"https://meet.google.com/abc-defg-hij\u00a0Room 5"},
			want:  "https://meet.google.com/abc-defg-hij",
		},
		{
			// Documented accepted false positive (spec-verbatim): only the
			// zoom arm is path-constrained; a non-meeting teams.microsoft.com
			// link still mints a Join button. Pinned so a future tightening
			// is a conscious change, not drift.
			name:  "teams non-meeting path matches (accepted false positive)",
			texts: []string{"https://teams.microsoft.com/downloads"},
			want:  "https://teams.microsoft.com/downloads",
		},
		{
			// Same accepted false positive for the webex arm.
			name:  "webex non-meeting path matches (accepted false positive)",
			texts: []string{"https://webex.com/pricing"},
			want:  "https://webex.com/pricing",
		},
		{
			name:  "location wins over description (first match)",
			texts: []string{"https://meet.google.com/loc-first-one", "https://zoom.us/j/999"},
			want:  "https://meet.google.com/loc-first-one",
		},
		{
			name:  "trailing sentence punctuation trimmed",
			texts: []string{"Join at https://meet.google.com/abc-defg-hij."},
			want:  "https://meet.google.com/abc-defg-hij",
		},
		{
			name:  "unrecognized host",
			texts: []string{"https://example.com/meeting", "Room 5"},
			want:  "",
		},
		{
			name:  "plain text without any link",
			texts: []string{"Room 5", "Weekly sync agenda"},
			want:  "",
		},
		{
			name:  "empty inputs",
			texts: []string{"", ""},
			want:  "",
		},
		{
			name:  "no inputs at all",
			texts: nil,
			want:  "",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			assert.Equal(t, tc.want, ExtractConferenceURL(tc.texts...))
		})
	}
}
