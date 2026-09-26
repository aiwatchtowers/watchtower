package doclinks

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestJiraKeys(t *testing.T) {
	assert.Equal(t, []string{"PROJ-12", "ABC_D-3"}, JiraKeys("See PROJ-12, then ABC_D-3 and again PROJ-12."))
	assert.Empty(t, JiraKeys("no keys here, proj-1 is lowercase"))
}

var testHosts = map[string]string{"acme.atlassian.net": "c1"}

func TestConfluencePageIDs(t *testing.T) {
	cases := []struct {
		name, text string
		want       []string
	}{
		{"slack link markup with title and label",
			"see <https://acme.atlassian.net/wiki/spaces/ENG/pages/12345/Payments+Design|Payments design> pls",
			[]string{"c1:12345"}},
		{"bare url, no title", "https://acme.atlassian.net/wiki/spaces/ENG/pages/777", []string{"c1:777"}},
		{"personal space", "https://acme.atlassian.net/wiki/spaces/~5b12ab34/pages/88/Notes", []string{"c1:88"}},
		{"url with query and anchor", "https://acme.atlassian.net/wiki/spaces/ENG/pages/99/Plan?focusedCommentId=5#Scope",
			[]string{"c1:99"}},
		{"deduped, first-seen order",
			"https://acme.atlassian.net/wiki/spaces/ENG/pages/2 and https://acme.atlassian.net/wiki/spaces/OPS/pages/1/X " +
				"and again https://acme.atlassian.net/wiki/spaces/ENG/pages/2/Y",
			[]string{"c1:2", "c1:1"}},
		{"foreign host is not ours", "https://other.atlassian.net/wiki/spaces/ENG/pages/5", nil},
		{"tiny link ignored in v1", "https://acme.atlassian.net/wiki/x/AbCdEf", nil},
		{"space overview is not a page", "https://acme.atlassian.net/wiki/spaces/ENG/overview", nil},
		{"no urls", "just text", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			assert.Equal(t, c.want, ConfluencePageIDs(c.text, testHosts))
		})
	}
	assert.Nil(t, ConfluencePageIDs("https://acme.atlassian.net/wiki/spaces/ENG/pages/5", nil), "no connected site: nothing matches")
}

func linksFrom(t *testing.T, d *db.DB, ref string) map[string]string {
	t.Helper()
	links, err := d.DocLinksFrom("confluence", ref)
	require.NoError(t, err)
	out := map[string]string{}
	for _, l := range links {
		require.Equal(t, "jira_issue", l.ToKind)
		out[l.ToRef] = l.DetectedAt
	}
	return out
}

// Every call replaces the fromRef's Jira-key links wholesale: removed
// mentions disappear, kept ones keep their detection time, other documents
// are untouched.
func TestLinkConfluenceDoc_ReplacesWholesale(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	const ref, other = "confluence:1:100", "confluence:1:200"
	require.NoError(t, LinkConfluenceDoc(ctx, d, other, "OTHER-1"))

	require.NoError(t, LinkConfluenceDoc(ctx, d, ref, "Design for PROJ-1", "comment: PROJ-2"))
	assert.ElementsMatch(t, []string{"PROJ-1", "PROJ-2"}, keysOf(linksFrom(t, d, ref)))
	_, err := d.Exec(`UPDATE doc_links SET detected_at = '2026-01-01T00:00:00Z' WHERE from_ref = ?`, ref)
	require.NoError(t, err)

	require.NoError(t, LinkConfluenceDoc(ctx, d, ref, "now PROJ-2 and PROJ-3"))
	got := linksFrom(t, d, ref)
	assert.ElementsMatch(t, []string{"PROJ-2", "PROJ-3"}, keysOf(got), "PROJ-1 was removed from the text")
	assert.Equal(t, "2026-01-01T00:00:00Z", got["PROJ-2"], "a kept mention keeps its detection time")

	require.NoError(t, LinkConfluenceDoc(ctx, d, ref))
	assert.Empty(t, linksFrom(t, d, ref), "no text = no links")
	assert.Equal(t, []string{"OTHER-1"}, keysOf(linksFrom(t, d, other)), "another document is untouched")
}

// Only the fromRef's jira_issue links are replaced; any other link kind the
// same ref might carry is not this writer's.
func TestLinkConfluenceDoc_LeavesOtherKinds(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	_, err := d.Exec(`INSERT INTO doc_links (from_kind, from_ref, to_kind, to_ref) VALUES ('confluence', 'confluence:1:1', 'confluence_page', 'c1:2')`)
	require.NoError(t, err)
	require.NoError(t, LinkConfluenceDoc(ctx, d, "confluence:1:1"))
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM doc_links`).Scan(&n))
	assert.Equal(t, 1, n)
}

func keysOf(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

func TestSiteHosts(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	_, err := d.Exec(`INSERT INTO jira_accounts (id, cloud_id, site_url, status) VALUES
		(1, 'c1', 'https://Acme.atlassian.net/', 'ok'),
		(2, 'c2', 'https://gone.atlassian.net', 'removed'),
		(3, '', 'https://nocloud.atlassian.net', 'ok'),
		(4, 'c4', '', 'ok')`)
	require.NoError(t, err)
	hosts, err := SiteHosts(ctx, d)
	require.NoError(t, err)
	assert.Equal(t, map[string]string{"acme.atlassian.net": "c1"}, hosts)
}
