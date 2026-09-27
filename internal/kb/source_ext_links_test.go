package kb

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// A page's meta carries how often it was discussed elsewhere — counts of
// distinct linking Slack documents and mails, never their content — and no
// such phrase at all while nothing links it.
func TestConfluence_MetaCountsInboundLinks(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedConfluence(t, d)
	src := extSource{provider: "confluence"}

	doc, err := src.Build(ctx, d, confluencePageRef)
	require.NoError(t, err)
	assert.NotContains(t, doc.Meta, "Discussed in")

	exec(t, d, `INSERT INTO doc_links (from_kind, from_ref, to_kind, to_ref) VALUES
		('slack', 'slack:thread:1:C1:1.0', 'confluence_page', 'c7:101'),
		('slack', 'slack:day:1:C2:2026-09-20', 'confluence_page', 'c7:101'),
		('gmail', 'gmail:1:t1', 'confluence_page', 'c7:101'),
		('imap', 'imap:1:7:42', 'confluence_page', 'c7:101'),
		('jira', 'jira:7:PROJ-1', 'confluence_page', 'c7:101'),
		('slack', 'slack:thread:1:C1:2.0', 'confluence_page', 'c7:999'),
		('slack', 'slack:thread:1:C1:3.0', 'confluence_page', 'other:101')`)
	doc, err = src.Build(ctx, d, confluencePageRef)
	require.NoError(t, err)
	assert.Contains(t, doc.Meta, "Discussed in: 2 Slack threads, 2 emails")

	att, err := src.Build(ctx, d, "confluence:1:att9")
	require.NoError(t, err)
	assert.NotContains(t, att.Meta, "Discussed in", "attachments are not page targets")
}

// The inbound-count lookup seeks idx_doc_links_to.
func TestConfluence_InboundCountQueryPlan(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	plan := explainPlanDetail(ctx, t, d, inboundCountsQuery, "c1:1")
	assert.Contains(t, plan, "USING INDEX idx_doc_links_to (to_kind=? AND to_ref=?)")
	assert.NotContains(t, plan, "SCAN doc_links")
}
