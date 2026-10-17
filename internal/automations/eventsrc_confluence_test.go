package automations

import (
	"context"
	"reflect"
	"testing"

	"watchtower/internal/db"
)

// confluenceFixture seeds Jira account "work" with the Confluence space ENG,
// backfilled or not, holding page 100 at version 1.
func confluenceFixture(t *testing.T, backfilled bool) (*db.DB, int64) {
	t.Helper()
	d := openEventDB(t)
	acct, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "c1", SiteURL: "https://acme.example.com", SiteName: "acme", Label: "work"})
	must(t, err)
	src, err := d.CreateExtSource("confluence", acct, "ENG", "1", "Engineering")
	must(t, err)
	if backfilled {
		_, err = d.Exec(`UPDATE ext_sources SET backfill_done = 1 WHERE id = ?`, src)
		must(t, err)
	}
	putConfluenceDoc(t, d, src, "100", "page", 1)
	return d, src
}

// putConfluenceDoc stores or replaces one document whose title and sections
// carry contentMarker.
func putConfluenceDoc(t *testing.T, d *db.DB, src int64, id, kind string, version int) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO ext_documents (source_id, ext_id, kind, title, version, sections_json)
        VALUES (?,?,?,?,?,?)
        ON CONFLICT(source_id, ext_id) DO UPDATE SET version = excluded.version`,
		src, id, kind, contentMarker, version, `[{"heading":"`+contentMarker+`","anchor":"a","text":"`+contentMarker+`"}]`)
	must(t, err)
}

// confluenceEvents runs the Confluence source around phase.
func confluenceEvents(t *testing.T, d *db.DB, phase func()) []Event {
	t.Helper()
	ctx := context.Background()
	src := ConfluenceSource(d)
	if src.Type() != "confluence.page_changed" {
		t.Errorf("Type() = %q", src.Type())
	}
	diff, err := src.Before(ctx)
	must(t, err)
	phase()
	events, err := diff.After(ctx)
	must(t, err)
	return events
}

func pageEvent(pageID string) Event {
	return Event{Type: "confluence.page_changed", Fields: map[string]any{"space": "ENG", "page_id": pageID}}
}

func TestConfluenceEvents_NewAndBumpedPages(t *testing.T) {
	d, src := confluenceFixture(t, true)
	putConfluenceDoc(t, d, src, "101", "page", 4)
	got := confluenceEvents(t, d, func() {
		putConfluenceDoc(t, d, src, "100", "page", 2)
		putConfluenceDoc(t, d, src, "102", "page", 1)
	})
	if want := []Event{pageEvent("100"), pageEvent("102")}; !reflect.DeepEqual(got, want) {
		t.Errorf("events = %+v\nwant %+v", got, want)
	}
}

func TestConfluenceEvents_BackfillPublishesNothing(t *testing.T) {
	d, src := confluenceFixture(t, false)
	got := confluenceEvents(t, d, func() {
		putConfluenceDoc(t, d, src, "100", "page", 2)
		putConfluenceDoc(t, d, src, "101", "page", 1)
		_, err := d.Exec(`UPDATE ext_sources SET backfill_done = 1 WHERE id = ?`, src)
		must(t, err)
	})
	if len(got) != 0 {
		t.Errorf("backfill published %+v", got)
	}
}

func TestConfluenceEvents_CommentOnlyChangeIsNotAnEvent(t *testing.T) {
	d, src := confluenceFixture(t, true)
	got := confluenceEvents(t, d, func() {
		_, err := d.Exec(`UPDATE ext_documents SET children_changed_at = '2026-10-03T00:00:00Z'
            WHERE source_id = ? AND ext_id = '100'`, src)
		must(t, err)
	})
	if len(got) != 0 {
		t.Errorf("comment-only change published %+v", got)
	}
}

func TestConfluenceEvents_BlogpostAndAttachmentIgnored(t *testing.T) {
	d, src := confluenceFixture(t, true)
	putConfluenceDoc(t, d, src, "200", "blogpost", 1)
	got := confluenceEvents(t, d, func() {
		putConfluenceDoc(t, d, src, "200", "blogpost", 2)
		putConfluenceDoc(t, d, src, "201", "blogpost", 1)
		putConfluenceDoc(t, d, src, "300", "attachment", 1)
	})
	if len(got) != 0 {
		t.Errorf("blog posts and attachments published %+v", got)
	}
}

// confluenceContentEvents builds Confluence events from the contentMarker
// fixtures for TestBus_EventsCarryNoContent.
func confluenceContentEvents(t *testing.T) []Event {
	d, src := confluenceFixture(t, true)
	events := confluenceEvents(t, d, func() {
		putConfluenceDoc(t, d, src, "100", "page", 2)
		putConfluenceDoc(t, d, src, "101", "page", 1)
	})
	if len(events) != 2 {
		t.Fatalf("confluence content fixture built %d events, want 2", len(events))
	}
	return events
}
