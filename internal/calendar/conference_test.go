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
