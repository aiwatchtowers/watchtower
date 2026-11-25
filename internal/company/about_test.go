package company

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/slackapp"
	"watchtower/internal/slackmanifest"
)

func TestConnectLink(t *testing.T) {
	assert.Equal(t, "http://127.0.0.1:18551/company/connect?b=eyJ2IjoxfQ", ConnectLink("eyJ2IjoxfQ"))
}

// fullAboutText is the uncut About layout, spelled out so a change to the
// wording shows up as a test diff.
func fullAboutText(company, link, code string) string {
	return "Watchtower for " + company + "\n\n" +
		"How to connect\n" +
		"1. Open Watchtower.\n" +
		"2. Click this link: " + link + "\n" +
		"   If it does not open, paste the code below in Watchtower → Connections → Company code.\n\n" +
		"Company code\n" +
		code + "\n\n" +
		"No Watchtower yet? Download it: " + slackapp.ReleasePage
}

func TestAboutText_FullLayout(t *testing.T) {
	link := ConnectLink("eyJ2IjoxfQ")
	assert.Equal(t, fullAboutText("Acme", link, "eyJ2IjoxfQ"), AboutText("Acme", link, "eyJ2IjoxfQ"))
}

func TestAboutText_CutsDownloadFirst(t *testing.T) {
	keptCodeWithoutDownload := false
	for n := 1000; n <= 3000; n += 10 {
		wire := strings.Repeat("A", n)
		link := ConnectLink(wire)
		text := AboutText("Acme", link, wire)
		if strings.Contains(text, "Company code\n"+wire) &&
			strings.Contains(text, "1. Open Watchtower.\n2. Click this link: "+link) &&
			!strings.Contains(text, "No Watchtower yet?") {
			keptCodeWithoutDownload = true
		}
		if strings.Contains(text, "No Watchtower yet?") {
			assert.Contains(t, text, "Company code\n", "the download line never outlives the code (n=%d)", n)
		}
	}
	assert.True(t, keptCodeWithoutDownload, "some size keeps the code and drops only the download line")
}

func TestAboutText_LargeBundleKeepsTheLinkOnly(t *testing.T) {
	wire := strings.Repeat("A", 3000)
	link := ConnectLink(wire)
	text := AboutText("Acme", link, wire)
	assert.Equal(t, "Watchtower for Acme\n\nHow to connect\n1. Open Watchtower.\n2. Click this link: "+link, text)
	_, err := slackmanifest.Description(text)
	require.NoError(t, err)
}

func TestAboutText_LinkNeverCut(t *testing.T) {
	for n := 1000; n <= 3000; n += 10 {
		wire := strings.Repeat("A", n)
		link := ConnectLink(wire)
		text := AboutText("Acme", link, wire)
		assert.Contains(t, text, "2. Click this link: "+link, n)
		if n <= 2900 {
			_, err := slackmanifest.Description(text)
			assert.NoError(t, err, n)
		}
	}
}

func TestAboutText_LongCompanyName(t *testing.T) {
	name := strings.Repeat("Acmé ", 40)
	require.Len(t, []rune(name), 200)
	link := ConnectLink("eyJ2IjoxfQ")
	assert.Equal(t, fullAboutText(name, link, "eyJ2IjoxfQ"), AboutText(name, link, "eyJ2IjoxfQ"))
}
