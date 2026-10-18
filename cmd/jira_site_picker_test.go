package cmd

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"watchtower/internal/jira"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// newAppSiteCmd is newSelectSiteCmd with `jira add`'s --app-site-picker set,
// the way the Desktop's connect sheet runs it (#574).
func newAppSiteCmd(t *testing.T, stdin string) (*cobra.Command, *bytes.Buffer) {
	t.Helper()
	cmd, out := newSelectSiteCmd(stdin)
	cmd.Flags().Bool("app-site-picker", false, "")
	require.NoError(t, cmd.Flags().Set("app-site-picker", "true"))
	return cmd, out
}

// Several sites under the app picker: one [jira-sites] JSON line naming
// every site, then the URL the sheet writes back on stdin picks the site.
func TestSelectJiraSite_AppPickerPrintsSitesAndReadsURL(t *testing.T) {
	cmd, out := newAppSiteCmd(t, "https://beta.atlassian.net\n")

	site, err := selectJiraSite(cmd, twoJiraSites(), "", "")
	require.NoError(t, err)
	assert.Equal(t, "cloud-b", site.ID)

	line := strings.TrimSpace(out.String())
	require.True(t, strings.HasPrefix(line, jiraSitesMarker+" "), "got %q", line)
	var payload struct {
		Sites []jiraSiteChoice `json:"sites"`
	}
	require.NoError(t, json.Unmarshal([]byte(strings.TrimPrefix(line, jiraSitesMarker+" ")), &payload))
	assert.Equal(t, []jiraSiteChoice{
		{URL: "https://alpha.atlassian.net", Name: "Alpha"},
		{URL: "https://beta.atlassian.net", Name: "Beta"},
	}, payload.Sites)
	assert.NotContains(t, out.String(), "Select site", "the app picker never prints the terminal prompt")
}

// No answer (the sheet closed stdin) or a URL outside the grant chooses
// nothing — never a fallback onto some site.
func TestSelectJiraSite_AppPickerWithoutAValidAnswerFails(t *testing.T) {
	for _, stdin := range []string{"", "\n", "https://gamma.atlassian.net\n", "beta\n"} {
		cmd, _ := newAppSiteCmd(t, stdin)
		_, err := selectJiraSite(cmd, twoJiraSites(), "", "")
		require.Error(t, err, "stdin %q", stdin)
		assert.Contains(t, err.Error(), "no site was chosen")
	}
}

// One site needs no list even under the app picker.
func TestSelectJiraSite_AppPickerSingleSiteAutoPicks(t *testing.T) {
	cmd, out := newAppSiteCmd(t, "")
	only := []jira.CloudResource{{ID: "cloud-only", URL: "https://only.atlassian.net", Name: "Only"}}

	site, err := selectJiraSite(cmd, only, "", "")
	require.NoError(t, err)
	assert.Equal(t, "cloud-only", site.ID)
	assert.Empty(t, out.String())
}

// `jira add` takes the flag: the Desktop passes it on every connect.
func TestJiraAddHasAppSitePickerFlag(t *testing.T) {
	assert.NotNil(t, jiraAddCmd.Flags().Lookup("app-site-picker"))
}
