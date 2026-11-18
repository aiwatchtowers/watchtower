package company

import (
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/slackmanifest"
)

func TestConnectLink(t *testing.T) {
	assert.Equal(t, "http://127.0.0.1:18551/company/connect?b=eyJ2IjoxfQ", ConnectLink("eyJ2IjoxfQ"))
}

func TestAboutText_LinkLeadsThenCode(t *testing.T) {
	require.False(t, aboutLeadsWithCode, "S1.2 default: the link leads")
	link := ConnectLink("eyJ2IjoxfQ")
	text := AboutText("Acme", link, "eyJ2IjoxfQ")
	lines := strings.Split(text, "\n")
	require.Len(t, lines, 3)
	assert.Equal(t, "Watchtower for Acme — connect: "+link, lines[0])
	assert.Contains(t, lines[1], "Connect code: eyJ2IjoxfQ")
	assert.Contains(t, lines[2], "No Watchtower yet?")
}

func TestAboutText_DropsTheCodeBeforeTheCap(t *testing.T) {
	wire := strings.Repeat("A", 1800) // a bundle near the wire cap: link + code + disclosures > 4000
	link := ConnectLink(wire)
	text := AboutText("Acme", link, wire)
	long, err := slackmanifest.Description(text)
	require.NoError(t, err)
	assert.LessOrEqual(t, utf8.RuneCountInString(long), slackmanifest.MaxLongDescription)
	assert.True(t, strings.HasPrefix(text, "Watchtower for Acme — connect: "+link), "the leading way in is never cut")
	assert.NotContains(t, text, "Connect code:")
}

func TestAboutText_DropsTheDownloadLineBeforeTheCode(t *testing.T) {
	keptCodeWithoutTail := false
	for n := 1000; n <= 3000; n += 10 {
		wire := strings.Repeat("A", n)
		link := ConnectLink(wire)
		text := AboutText("Acme", link, wire)
		if strings.HasPrefix(text, "Watchtower for Acme — connect: "+link+"\n") && len(strings.Split(text, "\n")) == 2 {
			assert.Contains(t, text, "Connect code: "+wire)
			keptCodeWithoutTail = true
		}
		if strings.Contains(text, "No Watchtower yet?") {
			assert.Contains(t, text, "Connect code:", "the download line never outlives the code")
		}
		if n <= 2900 {
			_, err := slackmanifest.Description(text)
			assert.NoError(t, err, n)
		}
	}
	assert.True(t, keptCodeWithoutTail, "some size keeps the code and drops only the download line")
}
