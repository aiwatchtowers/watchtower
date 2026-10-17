package db

import (
	"testing"
)

func TestAutomationEventSources_SlackReads(t *testing.T) {
	d := openTestDB(t)
	acct, err := d.CreateSlackAccount(SlackAccount{TeamDomain: "acme", Label: "work", CurrentUserID: "1:UOWNER"})
	if err != nil {
		t.Fatal(err)
	}
	if acct != 1 {
		t.Fatalf("account id %d, want 1", acct)
	}
	if err := d.UpsertChannel(Channel{ID: "1:C1", Name: "releases", Type: "public"}); err != nil {
		t.Fatal(err)
	}
	if err := d.UpdateSyncState("1:C1", SyncState{LastSyncedTS: "1700000000.000100", IsInitialSyncComplete: true}); err != nil {
		t.Fatal(err)
	}
	if err := d.UpdateSyncState("1:C2", SyncState{LastSyncedTS: ""}); err != nil {
		t.Fatal(err)
	}
	for _, m := range []Message{
		{ChannelID: "1:C1", TS: "1700000000.000100", UserID: "1:UA"},     // at the mark: not after
		{ChannelID: "1:C1", TS: "1700000001.000100", UserID: "1:UA"},     // counted
		{ChannelID: "1:C1", TS: "1700000002.000100", UserID: "1:UOWNER"}, // owner: excluded
		{ChannelID: "1:C1", TS: "1700000003.000100", UserID: "1:UA", IsDeleted: true},
		{ChannelID: "1:C1", TS: "1700000004.000100", UserID: ""}, // no user: counted
	} {
		if err := d.UpsertMessage(m); err != nil {
			t.Fatal(err)
		}
	}

	marks, err := d.SlackChannelSyncMarks()
	if err != nil {
		t.Fatal(err)
	}
	if got := marks["1:C1"]; got != (SlackSyncMark{LastSyncedTS: "1700000000.000100", InitialSyncComplete: true}) {
		t.Errorf("C1 mark = %+v", got)
	}
	if got, ok := marks["1:C2"]; !ok || got.InitialSyncComplete || got.LastSyncedTS != "" {
		t.Errorf("C2 mark = %+v, %v", got, ok)
	}

	n, err := d.CountSlackMessagesAfter("1:C1", "1700000000.000100", "1:UOWNER")
	if err != nil || n != 2 {
		t.Errorf("count = %d, %v; want 2", n, err)
	}
	n, err = d.CountSlackMessagesAfter("1:C1", "1700000000.000100", "")
	if err != nil || n != 3 {
		t.Errorf("count without owner = %d, %v; want 3", n, err)
	}

	label, owner, err := d.SlackEventLabels(acct)
	if err != nil || label != "work" || owner != "1:UOWNER" {
		t.Errorf("labels = %q, %q, %v", label, owner, err)
	}
	unlabelled, err := d.CreateSlackAccount(SlackAccount{TeamDomain: "acme-home"})
	if err != nil {
		t.Fatal(err)
	}
	label, owner, err = d.SlackEventLabels(unlabelled)
	if err != nil || label != "acme-home" || owner != "" {
		t.Errorf("fallback labels = %q, %q, %v", label, owner, err)
	}
	if _, _, err := d.SlackEventLabels(99); err == nil {
		t.Error("missing account: want an error")
	}
}

func TestAutomationEventSources_MailReads(t *testing.T) {
	d := openTestDB(t)
	g, err := d.CreateGoogleAccount(GoogleAccount{Email: "owner@example.com", Label: "work"})
	if err != nil {
		t.Fatal(err)
	}
	im, err := d.CreateEmailAccount(EmailAccount{Provider: "imap", EmailAddress: "owner@example.com", Host: "imap.example.com", Security: "ssl", Folder: "INBOX"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`UPDATE email_accounts SET label = '' WHERE id = ?`, im); err != nil {
		t.Fatal(err)
	}

	if label, err := d.MailEventLabel("gmail", g); err != nil || label != "work" {
		t.Errorf("gmail label = %q, %v", label, err)
	}
	if label, err := d.MailEventLabel("imap", im); err != nil || label != "owner@example.com" {
		t.Errorf("imap label = %q, %v", label, err)
	}
	if _, err := d.MailEventLabel("pop3", g); err == nil {
		t.Error("unknown provider: want an error")
	}
	if _, err := d.MailEventLabel("gmail", 99); err == nil {
		t.Error("missing account: want an error")
	}

	for _, p := range []string{"gmail", "imap"} {
		id := g
		if p == "imap" {
			id = im
		}
		if set, err := d.MailWatermarkSet(p, id); err != nil || set {
			t.Errorf("%s before sync: set=%v, %v", p, set, err)
		}
	}
	if err := d.SetGmailAccountWatermark(g, 1700000000); err != nil {
		t.Fatal(err)
	}
	if err := d.SetImapWatermark(im, 42, 7); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{"gmail", "imap"} {
		id := g
		if p == "imap" {
			id = im
		}
		if set, err := d.MailWatermarkSet(p, id); err != nil || !set {
			t.Errorf("%s after sync: set=%v, %v", p, set, err)
		}
	}
	if _, err := d.MailWatermarkSet("pop3", g); err == nil {
		t.Error("unknown provider: want an error")
	}
}

func TestAutomationEventSources_JiraReads(t *testing.T) {
	d := openTestDB(t)
	acct, err := d.CreateJiraAccount(JiraAccount{CloudID: "c1", SiteURL: "https://acme.example.com", SiteName: "acme", Label: "work"})
	if err != nil {
		t.Fatal(err)
	}
	issue := func(key, status string, deleted bool) JiraIssue {
		return JiraIssue{AccountID: acct, Key: key, ProjectKey: "PAY", Summary: "s", Status: status,
			StatusCategory: "new", AssigneeAccountID: "A1", Priority: "High",
			CreatedAt: "2026-10-01T00:00:00Z", UpdatedAt: "2026-10-02T00:00:00Z", SyncedAt: "2026-10-02T00:00:00Z", IsDeleted: deleted}
	}
	for _, i := range []JiraIssue{issue("PAY-1", "Open", false), issue("PAY-2", "Done", true)} {
		if err := d.UpsertJiraIssue(i); err != nil {
			t.Fatal(err)
		}
	}
	if err := d.UpsertJiraComments([]JiraComment{
		{AccountID: acct, IssueKey: "PAY-1", ID: "10"}, {AccountID: acct, IssueKey: "PAY-1", ID: "11"},
	}); err != nil {
		t.Fatal(err)
	}

	marks, err := d.JiraIssueMarks()
	if err != nil {
		t.Fatal(err)
	}
	want := JiraIssueMark{Project: "PAY", Status: "Open", Assignee: "A1", Priority: "High", UpdatedAt: "2026-10-02T00:00:00Z", Comments: 2}
	if len(marks) != 1 || marks[JiraIssueRef{AccountID: acct, Key: "PAY-1"}] != want {
		t.Errorf("marks = %+v, want only PAY-1 = %+v (deleted issues left out)", marks, want)
	}

	if label, err := d.JiraEventLabel(acct); err != nil || label != "work" {
		t.Errorf("label = %q, %v", label, err)
	}
	if _, err := d.Exec(`UPDATE jira_accounts SET label = '' WHERE id = ?`, acct); err != nil {
		t.Fatal(err)
	}
	if label, err := d.JiraEventLabel(acct); err != nil || label != "acme" {
		t.Errorf("fallback label = %q, %v", label, err)
	}
	if _, err := d.JiraEventLabel(99); err == nil {
		t.Error("missing account: want an error")
	}
}

func TestAutomationEventSources_CalendarReads(t *testing.T) {
	d := openTestDB(t)
	g, err := d.CreateGoogleAccount(GoogleAccount{Email: "owner@example.com", Label: "work"})
	if err != nil {
		t.Fatal(err)
	}
	dav, err := d.CreateCalendarAccount(CalendarAccount{Provider: "caldav", URL: "https://dav.example.com", Username: "owner", Label: "home"})
	if err != nil {
		t.Fatal(err)
	}
	davCal := CalendarAccountCalendarID("caldav", dav)
	for acct, id := range map[int64]string{g: "primary@example.com", 0: davCal} {
		if err := d.UpsertCalendar(acct, CalendarCalendar{ID: id, Name: "n", IsSelected: true}); err != nil {
			t.Fatal(err)
		}
	}
	if err := d.UpsertCalendar(0, CalendarCalendar{ID: "detached@example.com", Name: "n"}); err != nil {
		t.Fatal(err)
	}
	ev := CalendarEvent{ID: "e1", CalendarID: "primary@example.com", StartTime: "2026-10-20T09:00:00Z",
		EndTime: "2026-10-20T10:00:00Z", EventStatus: "confirmed", UpdatedAt: "2026-10-01T00:00:00Z"}
	if err := d.UpsertCalendarEvent(ev); err != nil {
		t.Fatal(err)
	}

	marks, err := d.CalendarEventMarks()
	if err != nil {
		t.Fatal(err)
	}
	want := CalendarEventMark{CalendarID: "primary@example.com", Status: "confirmed", UpdatedAt: "2026-10-01T00:00:00Z",
		Start: "2026-10-20T09:00:00Z", End: "2026-10-20T10:00:00Z"}
	if len(marks) != 1 || marks["e1"] != want {
		t.Errorf("marks = %+v, want e1 = %+v", marks, want)
	}

	cases := []struct {
		calendar, want string
		ok             bool
	}{
		{"primary@example.com", "work", true},
		{davCal, "home", true},
		{"detached@example.com", "", false},
		{"missing@example.com", "", false},
		{"ics:99", "", false},
	}
	for _, c := range cases {
		got, ok, err := d.CalendarEventLabel(c.calendar)
		if err != nil || ok != c.ok || got != c.want {
			t.Errorf("%s: label = %q, %v, %v; want %q, %v", c.calendar, got, ok, err, c.want, c.ok)
		}
	}
	if _, err := d.Exec(`UPDATE google_accounts SET label = '' WHERE id = ?`, g); err != nil {
		t.Fatal(err)
	}
	if got, ok, err := d.CalendarEventLabel("primary@example.com"); err != nil || !ok || got != "owner@example.com" {
		t.Errorf("google fallback label = %q, %v, %v", got, ok, err)
	}
}

func TestAutomationEventSources_ConfluenceReads(t *testing.T) {
	d := openTestDB(t)
	acct, err := d.CreateJiraAccount(JiraAccount{CloudID: "c1", SiteURL: "https://acme.example.com", SiteName: "acme", Label: "work"})
	if err != nil {
		t.Fatal(err)
	}
	src, err := d.CreateExtSource("confluence", acct, "ENG", "1", "Engineering")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`UPDATE ext_sources SET backfill_done = 1 WHERE id = ?`, src); err != nil {
		t.Fatal(err)
	}
	for _, doc := range []struct {
		id, kind string
		version  int
	}{{"100", "page", 3}, {"200", "blogpost", 1}, {"300", "attachment", 2}} {
		if _, err := d.Exec(`INSERT INTO ext_documents (source_id, ext_id, kind, title, version) VALUES (?,?,?,?,?)`,
			src, doc.id, doc.kind, "t", doc.version); err != nil {
			t.Fatal(err)
		}
	}

	versions, err := d.ConfluencePageVersions()
	if err != nil {
		t.Fatal(err)
	}
	if len(versions) != 1 || versions[ConfluencePageRef{SourceID: src, PageID: "100"}] != 3 {
		t.Errorf("versions = %+v, want only page 100 at version 3", versions)
	}

	sources, err := d.ConfluenceSourceMarks()
	if err != nil {
		t.Fatal(err)
	}
	if want := (ConfluenceSourceMark{Space: "ENG", BackfillDone: true}); len(sources) != 1 || sources[src] != want {
		t.Errorf("sources = %+v, want %d = %+v", sources, src, want)
	}
}
