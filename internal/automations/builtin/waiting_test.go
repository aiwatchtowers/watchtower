package builtin

import (
	"context"
	"encoding/json"
	"fmt"
	"maps"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/blocks"
	"watchtower/internal/db"
)

const waitingID = "waiting-for-me"

// openItemsFixture is the open-items fixture the Desktop's InboxRefState
// tests read too.
const openItemsFixture = "../../inbox/testdata/open_items.json"

// waitingCard is the Waiting for me artifact as stored: its key, title and
// list blocks (Today, This week, Older — each only when it has rows — or
// one empty list).
type waitingCard struct {
	key, title string
	lists      []*blocks.List
}

// rows is every row of every list, in order.
func (c waitingCard) rows() []blocks.ListRow {
	var out []blocks.ListRow
	for _, l := range c.lists {
		out = append(out, l.Rows...)
	}
	return out
}

// waitingArtifacts reads every inbox output of Waiting for me.
func (f *fixture) waitingArtifacts(t *testing.T) []waitingCard {
	t.Helper()
	rows, err := f.d.Query(`SELECT output_key, title, blocks_json FROM automation_outputs
		WHERE automation_id = ? AND kind = 'inbox' ORDER BY id`, f.rowOf(t, waitingID).ID)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []waitingCard
	for rows.Next() {
		var c waitingCard
		var stored string
		if err := rows.Scan(&c.key, &c.title, &stored); err != nil {
			t.Fatal(err)
		}
		doc, err := blocks.Decode(stored)
		if err != nil || len(doc.Blocks) == 0 {
			t.Fatalf("blocks %s: %v; want list blocks", stored, err)
		}
		for _, b := range doc.Blocks {
			if b.List == nil {
				t.Fatalf("blocks %s: want list blocks only", stored)
			}
			c.lists = append(c.lists, b.List)
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

// outputsSnapshot is every column of every automation_outputs row, for a
// byte-for-byte comparison.
func (f *fixture) outputsSnapshot(t *testing.T) string {
	t.Helper()
	rows, err := f.d.Query(`SELECT * FROM automation_outputs ORDER BY id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		t.Fatal(err)
	}
	var b strings.Builder
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			t.Fatal(err)
		}
		for i, c := range cols {
			fmt.Fprintf(&b, "%s=%v;", c, vals[i])
		}
		b.WriteString("\n")
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return b.String()
}

func TestWaitingForMe_ShippedRecipeHasNoLLM(t *testing.T) {
	e, ok := Lookup(waitingID)
	if !ok {
		t.Fatal("no waiting-for-me built-in")
	}
	r, err := ParseShipped(e)
	if err != nil {
		t.Fatal(err)
	}
	if n := automations.LLMCallSites(r.Script); n != 0 {
		t.Errorf("LLMCallSites = %d, want 0", n)
	}
	if r.Artifacts != automations.ArtifactsLiving || r.Trigger.Sync != string(SlotWaitingForMe) || r.Concurrency != 1 {
		t.Errorf("recipe = artifacts %q, sync %q, concurrency %d", r.Artifacts, r.Trigger.Sync, r.Concurrency)
	}
	if e.DefaultFolder != RootFolder || !e.RunNow || !slices.Equal(e.FeatureIDs, []string{"secretary-inbox"}) {
		t.Errorf("entry = %+v", e)
	}
	for _, p := range e.Primitives {
		if !slices.Contains(automations.ReadPrimitiveNames, p) {
			t.Errorf("primitive %s is not a read primitive", p)
		}
	}
}

// Over the shared fixture the run writes one living artifact `waiting`
// with one ref row per open people item (mail is in mail_items, not
// items), newest first, worded as the Desktop's message rows; the run costs
// no tokens.
func TestWaitingForMe_WritesOneRowPerOpenItem(t *testing.T) {
	f := newFixture(t)
	fx := db.SeedTestOpenItemsFixture(t, f.d, openItemsFixture)
	f.clock.Set(fx.Now)
	f.sync(t)
	run := f.runOnce(t, waitingID)
	if run.Status != db.RunSucceeded {
		t.Fatalf("run = %+v", run)
	}
	if run.InputTokens != 0 || run.OutputTokens != 0 {
		t.Errorf("run spent %d+%d tokens; want none", run.InputTokens, run.OutputTokens)
	}
	cards := f.waitingArtifacts(t)
	if len(cards) != 1 || cards[0].key != "waiting" || cards[0].title != "Waiting for me" {
		t.Fatalf("artifacts = %+v; want one `waiting`", cards)
	}
	var ids []int64
	byID := map[int64]blocks.ListRow{}
	for _, r := range cards[0].rows() {
		if r.Ref == nil || r.Ref.Kind != blocks.RefInboxItem {
			t.Fatalf("row %+v has no inbox_item ref", r)
		}
		ids = append(ids, r.Ref.ID)
		byID[r.Ref.ID] = r
	}
	// Item 15 is the fixture's one open mail item.
	people := slices.DeleteFunc(slices.Clone(fx.OpenIDs), func(id int64) bool { return id == 15 })
	if !slices.Equal(ids, people) {
		t.Fatalf("row refs = %v, want %v", ids, people)
	}
	checks := []struct {
		id                     int64
		title, subtitle, badge string
		tone, link             string
	}{
		{1, "Colleague A in #general", "Can you look at the release notes?", "2 h", "", "https://acme.slack.com/archives/C001/p10000001"},
		{2, "Colleague A in a DM", "Got a minute?", "1 h", "", "https://acme.slack.com/archives/D001/p10000002"},
		{17, "Colleague A in #general", "3 mentions · Any news on the launch?", "< 1 h", "", "https://acme.slack.com/archives/C001/p10000017"},
		{18, "Colleague A in #general", "", "2 h", "", ""},
		{10, "ACME-1 — assigned to you", "Fix the login page", "2 days", "warning", "https://acme.atlassian.net/browse/ACME-1"},
		{16, "ENG-7 — assigned to you", "Tidy the settings screen", "16 h", "", "https://linear.app/acme/issue/ENG-7"},
	}
	for _, c := range checks {
		r := byID[c.id]
		if r.Title != c.title || r.Subtitle != c.subtitle || r.Badge == nil || r.Badge.Text != c.badge || r.Tone != c.tone || r.Link != c.link {
			t.Errorf("row %d = title %q subtitle %q badge %+v tone %q link %q; want %q %q %q %q %q",
				c.id, r.Title, r.Subtitle, r.Badge, r.Tone, r.Link, c.title, c.subtitle, c.badge, c.tone, c.link)
		}
	}
}

// With nothing open the run still writes the artifact, its list empty with
// "Nobody is waiting on you"; a later run with an item rewrites the same
// artifact (one key, one row).
func TestWaitingForMe_EmptyThenOneItem(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	if run := f.runOnce(t, waitingID); run.Status != db.RunSucceeded {
		t.Fatalf("run = %+v", run)
	}
	cards := f.waitingArtifacts(t)
	if len(cards) != 1 || len(cards[0].lists) != 1 || len(cards[0].lists[0].Rows) != 0 || cards[0].lists[0].Empty != "Nobody is waiting on you" {
		t.Fatalf("artifacts = %+v; want one empty `waiting`", cards)
	}
	f.insertItem(t, "1000.0001", "mention", f.clock.Now())
	if run := f.runOnce(t, waitingID); run.Status != db.RunSucceeded {
		t.Fatalf("run = %+v", run)
	}
	if cards = f.waitingArtifacts(t); len(cards) != 1 || len(cards[0].rows()) != 1 {
		t.Fatalf("artifacts = %+v; want one `waiting` with one row", cards)
	}
}

// insertItem adds one open Slack item without text or names.
func (f *fixture) insertItem(t *testing.T, ts, trigger string, at time.Time) {
	t.Helper()
	if _, err := f.d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, created_at)
		VALUES ('C009', ?, 'U009', ?, ?)`, ts, trigger, at.UTC().Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
}

// An item with no text, no known sender and no channel row still makes a
// row: a fallback title and no subtitle.
func TestWaitingForMe_ItemWithEmptyText(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.insertItem(t, "1000.0001", "mention", f.clock.Now().Add(-5*time.Minute))
	if run := f.runOnce(t, waitingID); run.Status != db.RunSucceeded {
		t.Fatalf("run = %+v", run)
	}
	rows := f.waitingArtifacts(t)[0].rows()
	if len(rows) != 1 || rows[0].Title != "Someone" || rows[0].Subtitle != "" || rows[0].Badge.Text != "< 1 h" || rows[0].Link != "" {
		t.Errorf("rows = %+v", rows)
	}
}

// At most 200 rows, the newest people items: newer mail takes none of them.
func TestWaitingForMe_CapsAt200(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	for i := 1; i <= 201; i++ {
		f.insertItem(t, fmt.Sprintf("1000.%04d", i), "mention", f.clock.Now().Add(-time.Duration(i)*time.Minute))
	}
	for i := 1; i <= 5; i++ {
		f.insertMail(t, fmt.Sprintf("2000.%04d", i), "a@example.com", "Hello", f.clock.Now())
	}
	if run := f.runOnce(t, waitingID); run.Status != db.RunSucceeded {
		t.Fatalf("run = %+v (%s)", run, run.Error)
	}
	rows := f.waitingArtifacts(t)[0].rows()
	if len(rows) != WaitingPeopleLimit || rows[0].Badge.Text != "< 1 h" || rows[0].Ref.ID != 1 {
		t.Errorf("%d rows, first %+v; want %d, the newest people item first", len(rows), rows[0], WaitingPeopleLimit)
	}
}

// A failed read fails the run (PrimitiveFailed) and leaves the earlier
// artifact as it was (AUTO-04); the Desktop then shows the Messages entry.
func TestWaitingForMe_PrimitiveErrorFailsRunKeepsArtifact(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.insertItem(t, "1000.0001", "mention", f.clock.Now())
	if run := f.runOnce(t, waitingID); run.Status != db.RunSucceeded {
		t.Fatalf("first run = %+v", run)
	}
	before := f.outputsSnapshot(t)
	if _, err := f.d.Exec(`ALTER TABLE inbox_items RENAME TO inbox_items_gone`); err != nil {
		t.Fatal(err)
	}
	f.clock.Advance(time.Hour)
	run := f.runOnce(t, waitingID)
	if run.Status != db.RunFailed || !strings.Contains(run.Error, automations.ErrNamePrimitiveFailed) {
		t.Fatalf("run = %+v; want failed with %s", run, automations.ErrNamePrimitiveFailed)
	}
	if after := f.outputsSnapshot(t); after != before {
		t.Errorf("outputs changed by a failed run:\nbefore %s\nafter  %s", before, after)
	}
}

// Attention detection off: the slot skips the built-in before any read and
// writes no run (FEAT-01).
func TestWaitingForMe_SkippedWhenDetectionOff(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.cfg.Inbox.Enabled = false
	out := f.runner.RunSlot(context.Background(), SlotWaitingForMe)
	if len(out) != 2 || out[0].BuiltinID != waitingID || out[0].Skipped != SkippedOff {
		t.Fatalf("slot = %+v; want waiting-for-me skipped off", out)
	}
	runs, err := f.d.ListAutomationRuns(f.rowOf(t, waitingID).ID, 0)
	if err != nil || len(runs) != 0 {
		t.Errorf("runs = %+v, %v; want none", runs, err)
	}
}

// The read primitive is journalled as one tool step, not a model call, and
// takes no argument.
func TestWaitingForMe_ReadIsAToolStep(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	run := f.runOnce(t, waitingID)
	steps, err := f.d.ListAutomationRunSteps(run.ID)
	if err != nil {
		t.Fatal(err)
	}
	var kinds []string
	for _, s := range steps {
		kinds = append(kinds, s.Kind+":"+s.Name)
	}
	if !slices.Contains(kinds, "tool:"+automations.PrimitiveAttentionWaiting) || slices.ContainsFunc(kinds, func(k string) bool {
		return strings.HasPrefix(k, "llm:")
	}) {
		t.Errorf("steps = %v; want a tool step and no llm step", kinds)
	}
}

// Ages are whole hours or days, never minutes: two runs within the same
// hour with nothing changed write the same content hash, so the living
// rewrite keeps the card's read state.
func TestWaitingForMe_SameHourSameHash(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.insertItem(t, "1000.0001", "mention", f.clock.Now().Add(-2*time.Hour-5*time.Minute))
	hash := func() string {
		t.Helper()
		if run := f.runOnce(t, waitingID); run.Status != db.RunSucceeded {
			t.Fatalf("run = %+v", run)
		}
		var h string
		if err := f.d.QueryRow(`SELECT content_hash FROM automation_outputs WHERE output_key = 'waiting'`).Scan(&h); err != nil {
			t.Fatal(err)
		}
		return h
	}
	first := hash()
	f.clock.Advance(20 * time.Minute)
	if second := hash(); second != first {
		t.Errorf("content hash moved within the hour: %s → %s", first, second)
	}
	f.clock.Advance(time.Hour)
	if third := hash(); third == first {
		t.Error("content hash kept after the age moved to the next hour")
	}
}

// 200 open items of 300 Cyrillic characters each would pass the block
// document's cap; the primitive's byte budget trims the texts so the run
// still succeeds with every row.
func TestWaitingForMe_ByteBudgetKeepsLongTextsUnderTheCap(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	text := strings.Repeat("Ж", 300)
	for i := 1; i <= WaitingPeopleLimit; i++ {
		if _, err := f.d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, snippet, permalink, created_at)
			VALUES ('C009', ?, 'U009', 'mention', ?, ?, ?)`, fmt.Sprintf("1000.%04d", i), text,
			fmt.Sprintf("https://acme.slack.com/archives/C009/p1000%04d", i),
			f.clock.Now().Add(-time.Duration(i)*time.Minute).UTC().Format(time.RFC3339)); err != nil {
			t.Fatal(err)
		}
	}
	run := f.runOnce(t, waitingID)
	if run.Status != db.RunSucceeded {
		t.Fatalf("run = %s (%s); want succeeded", run.Status, run.Error)
	}
	rows := f.waitingArtifacts(t)[0].rows()
	if len(rows) != WaitingPeopleLimit || rows[0].Subtitle == "" || !strings.HasSuffix(rows[0].Subtitle, "…") || rows[0].Link == "" {
		t.Errorf("%d rows, first %+v; want %d rows with trimmed texts and their links", len(rows), rows[0], WaitingPeopleLimit)
	}
}

func TestClipJSON(t *testing.T) {
	for _, c := range []struct {
		in   string
		max  int
		want string
	}{
		{"abc", 5, "abc"},
		{"abcdef", 7, "ab…"},
		{"ЖЖЖЖ", 9, "ЖЖ…"},
		{"abc", 2, ""},
		{`a"b"c`, 8, `a"…`},
	} {
		if got := clipJSON(c.in, c.max); got != c.want || jsonLen(got) > max(c.max, 2) {
			t.Errorf("clipJSON(%q, %d) = %q, want %q", c.in, c.max, got, c.want)
		}
	}
}

// The fingerprint is stable while nothing shown changes, moves with a new
// item, and ignores a minute that leaves every age as it reads.
func TestWaitingFingerprint(t *testing.T) {
	f := newFixture(t)
	ctx, now := context.Background(), f.clock.Now()
	f.insertItem(t, "1000.0001", "mention", now.Add(-2*time.Hour-5*time.Minute))
	fp := func(at time.Time) string {
		t.Helper()
		s, err := WaitingFingerprint(ctx, f.d, at, db.WaitingPeople)
		if err != nil {
			t.Fatal(err)
		}
		return s
	}
	first := fp(now)
	if fp(now.Add(20*time.Minute)) != first {
		t.Error("fingerprint moved within the hour")
	}
	if fp(now.Add(time.Hour)) == first {
		t.Error("fingerprint kept after the age moved")
	}
	f.insertItem(t, "1000.0002", "mention", now)
	if fp(now) == first {
		t.Error("fingerprint kept after a new item")
	}
}

// An item whose stamp does not parse gets no badge (never a made-up age).
func TestWaitingForMe_UnparsableStampHasNoBadge(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	if _, err := f.d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, created_at)
		VALUES ('C009', '1000.0001', 'U009', 'mention', 'not a time')`); err != nil {
		t.Fatal(err)
	}
	if run := f.runOnce(t, waitingID); run.Status != db.RunSucceeded {
		t.Fatalf("run = %+v", run)
	}
	// The section of an unparsable stamp is Older (db.WaitingSectionOf), so
	// the Older note row comes first; the item's own row has no badge.
	rows := slices.DeleteFunc(f.waitingArtifacts(t)[0].rows(), func(r blocks.ListRow) bool {
		return r.Ref != nil && r.Ref.Kind == blocks.RefWaitingOlder
	})
	if len(rows) != 1 || rows[0].Badge != nil || rows[0].Tone != "" {
		t.Errorf("rows = %+v; want one row without a badge or tone", rows)
	}
}

// TestWaitingForMe_WebLinkKeepsOnlyLinksTheBlocksAdmit: a permalink the
// blocks would refuse is dropped so it cannot fail the whole run, and so is
// an in-app watchtower-nav:// link the blocks admit: a source permalink is a
// web link, never an in-app jump.
func TestWaitingForMe_WebLinkKeepsOnlyLinksTheBlocksAdmit(t *testing.T) {
	long := "https://acme.example.com/" + strings.Repeat("a", blocks.MaxLinkBytes)
	cases := map[string]string{
		"https://acme.example.com/archives/C1/p1": "https://acme.example.com/archives/C1/p1",
		"HTTP://acme.example.com/x":               "HTTP://acme.example.com/x",
		"":                                        "",
		"ftp://acme.example.com/x":                "",
		"watchtower-nav://inbox":                  "",
		"WATCHTOWER-NAV://home/x":                 "",
		"https:///no-host":                        "",
		"javascript:alert(1)":                     "",
		"%zz":                                     "",
		long:                                      "",
	}
	for in, want := range cases {
		if got := webLink(in); got != want {
			t.Errorf("webLink(%.40q) = %q, want %q", in, got, want)
		}
	}
}

// insertMail adds one open mail item from sender (stored as is) whose
// snippet is "<subject> — body".
func (f *fixture) insertMail(t *testing.T, ts, sender, subject string, at time.Time) {
	t.Helper()
	if _, err := f.d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, snippet, created_at)
		VALUES ('gmail', ?, ?, 'email_received', ?, ?)`, ts, sender, subject+" — body",
		at.UTC().Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
}

// waitingFields is attention.waiting's result at now.
func waitingFields(t *testing.T, d *db.DB, now time.Time) map[string]any {
	t.Helper()
	read := WaitingPrimitives(d, func() time.Time { return now })[automations.PrimitiveAttentionWaiting]
	res, err := read(context.Background(), automations.PrimitiveCall{})
	if err != nil || res.Status != "done" {
		t.Fatalf("attention.waiting = %+v, %v", res, err)
	}
	return res.Fields
}

// rowsOf is a list field of the result as maps.
func rowsOf(t *testing.T, fields map[string]any, key string) []map[string]any {
	t.Helper()
	list, ok := fields[key].([]any)
	if !ok {
		t.Fatalf("%s = %T; want a list", key, fields[key])
	}
	out := make([]map[string]any, 0, len(list))
	for _, r := range list {
		out = append(out, r.(map[string]any))
	}
	return out
}

// 250 people and 250 mail items: items holds the 200 newest people items,
// mail_items the 200 newest mail items, each row tagged with its kind; the
// counts cover every item.
func TestAttentionWaiting_SplitsKindsWithSeparateCaps(t *testing.T) {
	f := newFixture(t)
	now := f.clock.Now()
	for i := 1; i <= 250; i++ {
		at := now.Add(-time.Duration(i) * time.Minute)
		f.insertItem(t, fmt.Sprintf("1000.%04d", i), "mention", at)
		f.insertMail(t, fmt.Sprintf("2000.%04d", i), fmt.Sprintf("s%d@example.com", i%7), "Hello", at.Add(30*time.Second))
	}
	fields := waitingFields(t, f.d, now)
	items, mail := rowsOf(t, fields, "items"), rowsOf(t, fields, "mail_items")
	if len(items) != WaitingPeopleLimit || len(mail) != WaitingMailLimit {
		t.Fatalf("%d items, %d mail items; want %d and %d", len(items), len(mail), WaitingPeopleLimit, WaitingMailLimit)
	}
	for i, r := range items {
		if r["kind"] != "people" || r["trigger"] != "mention" {
			t.Fatalf("items[%d] = %v; want a people row", i, r)
		}
	}
	for i, r := range mail {
		if r["kind"] != "mail" || r["trigger"] != "email_received" {
			t.Fatalf("mail_items[%d] = %v; want a mail row", i, r)
		}
	}
	if items[0]["at"].(string) < items[1]["at"].(string) || mail[0]["at"].(string) < mail[1]["at"].(string) {
		t.Error("rows are not newest first")
	}
	people := fields["people"].(map[string]any)
	if people["open"] != 250 || people["today"].(int)+people["week"].(int)+people["older"].(int) != 250 {
		t.Errorf("people = %v; want 250 open", people)
	}
	m := fields["mail"].(map[string]any)
	if m["open"] != 250 || m["senders"] != 7 || m["top_ten_share"] != 100 {
		t.Errorf("mail = %v; want 250 open from 7 senders", m)
	}
	if n := len(rowsOf(t, fields, "senders")); n != 7 {
		t.Errorf("%d senders; want 7", n)
	}
}

// waitingForMePrePhase2 is Waiting for me's recipe as shipped before the
// people/mail split: it reads items only.
const waitingForMePrePhase2 = "testdata/waiting_for_me_pre_phase2.md"

// An owner's copy of Waiting for me written before the split (overridden,
// confirmed) still runs: one row per open people item, at most 200, and no
// mail row even when the mail is the newest.
func TestAttentionWaiting_OwnerCopyOfWaitingForMeGetsNoMail(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	text, err := os.ReadFile(waitingForMePrePhase2)
	if err != nil {
		t.Fatal(err)
	}
	f.writeCopyOf(t, waitingID, text)
	f.sync(t)
	a := f.rowOf(t, waitingID)
	if !a.Overridden || a.ParseError != "" {
		t.Fatalf("row = overridden %v parse %q; want the owner's copy", a.Overridden, a.ParseError)
	}
	if err := f.d.ConfirmAutomation(a.ID, a.ApprovalHash, f.clock.Now()); err != nil {
		t.Fatal(err)
	}
	now := f.clock.Now()
	for i := 1; i <= 3; i++ {
		f.insertMail(t, fmt.Sprintf("2000.%04d", i), "a@example.com", "Hello", now)
	}
	check := func(want int) {
		t.Helper()
		if run := f.runOnce(t, waitingID); run.Status != db.RunSucceeded {
			t.Fatalf("run = %+v (%s)", run, run.Error)
		}
		var mailIDs []int64
		idRows, err := f.d.Query(`SELECT id FROM inbox_items WHERE trigger_type = 'email_received'`)
		if err != nil {
			t.Fatal(err)
		}
		for idRows.Next() {
			var id int64
			if err := idRows.Scan(&id); err != nil {
				t.Fatal(err)
			}
			mailIDs = append(mailIDs, id)
		}
		if err := idRows.Close(); err != nil || len(mailIDs) != 3 {
			t.Fatalf("mail ids = %v, %v", mailIDs, err)
		}
		rows := f.waitingArtifacts(t)[0].rows()
		if len(rows) != want {
			t.Fatalf("%d rows; want %d", len(rows), want)
		}
		for _, r := range rows {
			if r.Ref == nil || r.Ref.Kind != blocks.RefInboxItem || slices.Contains(mailIDs, r.Ref.ID) {
				t.Fatalf("row %+v; want a people item's row", r)
			}
		}
	}
	for i := 1; i <= 2; i++ {
		f.insertItem(t, fmt.Sprintf("1000.%04d", i), "mention", now.Add(-time.Duration(i)*time.Minute))
	}
	check(2)
	for i := 3; i <= 201; i++ {
		f.insertItem(t, fmt.Sprintf("1000.%04d", i), "mention", now.Add(-time.Duration(i)*time.Minute))
	}
	check(WaitingPeopleLimit)
}

// A raw From address the ref would refuse is still grouped and counted,
// but not actionable.
func TestAttentionWaiting_SenderNotActionable(t *testing.T) {
	f := newFixture(t)
	now := f.clock.Now()
	long := strings.Repeat("a", 288) + "@example.com" // 300 bytes
	raw := []string{`"Name" <a@example.com>`, "a@@example.com", "a b@example.com", long, "ok@example.com"}
	for i, s := range raw {
		f.insertMail(t, fmt.Sprintf("2000.%04d", 2*i), s, "Hello", now.Add(-time.Duration(i)*time.Minute))
		f.insertMail(t, fmt.Sprintf("2000.%04d", 2*i+1), s, "Hello", now.Add(-time.Duration(i)*time.Minute))
	}
	fields := waitingFields(t, f.d, now)
	got := map[string]map[string]any{}
	for _, s := range rowsOf(t, fields, "senders") {
		got[s["address"].(string)] = s
	}
	want := map[string]bool{`"name" <a@example.com>`: false, "a@@example.com": false, "a b@example.com": false,
		long: false, "ok@example.com": true}
	for addr, actionable := range want {
		s, ok := got[addr]
		if !ok {
			t.Errorf("no sender %.40q in %v", addr, got)
			continue
		}
		if s["actionable"] != actionable || s["open"] != 2 {
			t.Errorf("sender %.40q = actionable %v open %v; want %v, 2", addr, s["actionable"], s["open"], actionable)
		}
	}
	if m := fields["mail"].(map[string]any); m["senders"] != len(raw) || m["open"] != 2*len(raw) {
		t.Errorf("mail = %v; want %d senders, %d open", m, len(raw), 2*len(raw))
	}
}

// Sections follow the clock's zone: just after local midnight is today, and
// an item of today's UTC date that is local yesterday is this week.
func TestAttentionWaiting_SectionsInLocalZone(t *testing.T) {
	f := newFixture(t)
	loc := time.FixedZone("UTC-5", -5*3600)
	now := time.Date(2026, 10, 22, 10, 0, 0, 0, loc) // 15:00 UTC
	f.insertItem(t, "1000.0001", "mention", time.Date(2026, 10, 22, 0, 30, 0, 0, loc))
	f.insertItem(t, "1000.0002", "mention", time.Date(2026, 10, 22, 2, 0, 0, 0, time.UTC)) // 21:00 local yesterday
	f.insertItem(t, "1000.0003", "mention", now.Add(-8*24*time.Hour))
	f.insertMail(t, "2000.0001", "a@example.com", "Hello", time.Date(2026, 10, 22, 2, 0, 0, 0, time.UTC))
	fields := waitingFields(t, f.d, now)
	sections := map[string]string{}
	for _, r := range rowsOf(t, fields, "items") {
		sections[r["at"].(string)] = r["section"].(string)
	}
	want := map[string]string{"2026-10-22T05:30:00Z": "today", "2026-10-22T02:00:00Z": "week", "2026-10-14T15:00:00Z": "older"}
	if !maps.Equal(sections, want) {
		t.Errorf("sections = %v; want %v", sections, want)
	}
	if p := fields["people"].(map[string]any); p["today"] != 1 || p["week"] != 1 || p["older"] != 1 || p["open"] != 3 {
		t.Errorf("people = %v; want 1 today, 1 week, 1 older", p)
	}
	if m := rowsOf(t, fields, "mail_items"); len(m) != 1 || m[0]["section"] != "week" {
		t.Errorf("mail_items = %v; want one week row", m)
	}
	if m := fields["mail"].(map[string]any); m["today"] != 0 {
		t.Errorf("mail = %v; want none today", m)
	}
}

// A muted sender's mail is in neither mail_items nor senders; its items
// stay open.
func TestAttentionWaiting_MutedSenderLeftOut(t *testing.T) {
	f := newFixture(t)
	now := f.clock.Now()
	f.insertMail(t, "2000.0001", "Muted@Example.com", "Spam", now)
	f.insertMail(t, "2000.0002", "kept@example.com", "Hello", now.Add(-time.Minute))
	if _, err := f.d.Exec(`INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, last_updated)
		VALUES ('source_mute', 'email:muted@example.com', -1, 'user_rule', ?)`, now.UTC().Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	fields := waitingFields(t, f.d, now)
	if m := rowsOf(t, fields, "mail_items"); len(m) != 1 || m[0]["who"] != "kept@example.com" {
		t.Errorf("mail_items = %v; want kept@example.com's only", m)
	}
	if s := rowsOf(t, fields, "senders"); len(s) != 1 || s[0]["address"] != "kept@example.com" {
		t.Errorf("senders = %v; want kept@example.com only", s)
	}
	if m := fields["mail"].(map[string]any); m["open"] != 1 || m["senders"] != 1 {
		t.Errorf("mail = %v; want 1 open from 1 sender", m)
	}
	var open int
	if err := f.d.QueryRow(`SELECT COUNT(*) FROM inbox_items WHERE status = 'pending'`).Scan(&open); err != nil || open != 2 {
		t.Errorf("pending items = %d, %v; want both still open", open, err)
	}
}

// The worst cases of the senders list: 200 senders whose addresses are the
// longest a ref admits, with links as long as the blocks admit; or 200 raw
// addresses full of characters JSON escapes (not actionable, so clipped).
// Beside 200 people and 200 mail items of long non-Latin text, names,
// subjects and links, the senders stay within their budget, the result
// under the SDK's cap, and the shipped recipe still writes every people row.
func TestAttentionWaiting_WorstCaseUnderSDKCap(t *testing.T) {
	link := func(i int) string {
		head := fmt.Sprintf("https://mail.example.com/m/%04d/", i)
		return head + strings.Repeat("a", blocks.MaxLinkBytes-len(head))
	}
	for name, c := range map[string]struct {
		address    func(i int) string
		actionable bool
	}{
		// 254 bytes: the longest address a ref admits.
		"longest actionable addresses": {func(i int) string {
			return fmt.Sprintf("%03dx", i) + strings.Repeat("ж", 119) + "@example.com"
		}, true},
		// 245 bytes that JSON would escape to about 935: refused as refs,
		// so clipped.
		"escaped raw addresses": {func(i int) string {
			return strings.Repeat(`&\`, 115) + fmt.Sprintf("%03d@example.com", i)
		}, false},
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			f.sync(t)
			now := f.clock.Now()
			long := strings.Repeat("Ж", 400)
			if _, err := f.d.Exec(`INSERT INTO users (id, name, display_name) VALUES ('U009', ?, ?)`, long, long); err != nil {
				t.Fatal(err)
			}
			if _, err := f.d.Exec(`INSERT INTO channels (id, name, type) VALUES ('C009', ?, 'public')`, long); err != nil {
				t.Fatal(err)
			}
			for i := 1; i <= 200; i++ {
				at := now.Add(-time.Duration(i) * time.Minute).UTC().Format(time.RFC3339)
				if _, err := f.d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, snippet, permalink, created_at)
					VALUES ('C009', ?, 'U009', 'mention', ?, ?, ?)`, fmt.Sprintf("1000.%04d", i), long, link(i), at); err != nil {
					t.Fatal(err)
				}
				if _, err := f.d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, snippet, permalink, created_at)
					VALUES ('gmail', ?, ?, 'email_received', ?, ?, ?)`, fmt.Sprintf("2000.%04d", i), c.address(i), long+" — "+long,
					link(i), at); err != nil {
					t.Fatal(err)
				}
			}
			fields := waitingFields(t, f.d, now)
			for key, want := range map[string]int{"items": WaitingPeopleLimit, "mail_items": WaitingMailLimit, "senders": WaitingSendersLimit} {
				if n := len(rowsOf(t, fields, key)); n != want {
					t.Errorf("%d %s; want %d", n, key, want)
				}
			}
			for _, s := range rowsOf(t, fields, "senders") {
				if s["actionable"] != c.actionable {
					t.Fatalf("sender %.60v; want actionable %v", s, c.actionable)
				}
				if c.actionable && len(s["address"].(string)) != 254 {
					t.Fatalf("sender %.60v; want its whole address", s)
				}
			}
			senders, err := json.Marshal(fields["senders"])
			if err != nil {
				t.Fatal(err)
			}
			if len(senders) > waitingSendersBudgetBytes {
				t.Errorf("senders are %d bytes; the budget is %d", len(senders), waitingSendersBudgetBytes)
			}
			data, err := json.Marshal(map[string]any{"status": "done", "fields": fields})
			if err != nil {
				t.Fatal(err)
			}
			if len(data) > automations.MaxSDKResultBytes {
				t.Errorf("result is %d bytes; the SDK's cap is %d", len(data), automations.MaxSDKResultBytes)
			}
			run := f.runOnce(t, waitingID)
			if run.Status != db.RunSucceeded {
				t.Fatalf("run = %s (%s); want succeeded", run.Status, run.Error)
			}
			if rows := f.waitingArtifacts(t)[0].rows(); len(rows) != WaitingPeopleLimit {
				t.Errorf("%d rows; want %d", len(rows), WaitingPeopleLimit)
			}
		})
	}
}

// Every sender row fits its even share of the budget, whatever its
// count: a few senders keep their links and long subjects, and the list
// never passes the budget.
func TestAttentionWaiting_SendersHardBudget(t *testing.T) {
	for _, n := range []int{1, 3, 57, 200} {
		f := newFixture(t)
		now := f.clock.Now()
		for i := 1; i <= n; i++ {
			addr := fmt.Sprintf("%03dx", i) + strings.Repeat("ж", 119) + "@example.com"
			if _, err := f.d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, snippet, permalink, created_at)
				VALUES ('gmail', ?, ?, 'email_received', ?, ?, ?)`, fmt.Sprintf("2000.%04d", i), addr,
				strings.Repeat("Ж", 400)+" — body", fmt.Sprintf("https://mail.example.com/m/%04d", i),
				now.Add(-time.Duration(i)*time.Minute).UTC().Format(time.RFC3339)); err != nil {
				t.Fatal(err)
			}
		}
		fields := waitingFields(t, f.d, now)
		senders := rowsOf(t, fields, "senders")
		data, err := json.Marshal(fields["senders"])
		if err != nil {
			t.Fatal(err)
		}
		if len(senders) != n || len(data) > waitingSendersBudgetBytes {
			t.Errorf("%d senders: %d rows, %d bytes; want %d rows within %d", n, len(senders), len(data), n, waitingSendersBudgetBytes)
		}
		if n <= 3 && (senders[0]["permalink"] == "" || senders[0]["subject"] == "") {
			t.Errorf("%d senders: first %.80v; want its link and subject", n, senders[0])
		}
	}
}

// A new mail item leaves the people fingerprint as it was and moves the
// mail one.
func TestWaitingFingerprint_PeopleIgnoresMail(t *testing.T) {
	f := newFixture(t)
	ctx, now := context.Background(), f.clock.Now()
	f.insertItem(t, "1000.0001", "mention", now.Add(-time.Hour))
	fp := func(kind db.WaitingKind) string {
		t.Helper()
		s, err := WaitingFingerprint(ctx, f.d, now, kind)
		if err != nil {
			t.Fatal(err)
		}
		return s
	}
	people, mail := fp(db.WaitingPeople), fp(db.WaitingMail)
	f.insertMail(t, "2000.0001", "a@example.com", "Hello", now)
	if fp(db.WaitingPeople) != people {
		t.Error("the people fingerprint moved with a mail item")
	}
	if fp(db.WaitingMail) == mail {
		t.Error("the mail fingerprint kept after a mail item")
	}
	if _, err := WaitingFingerprint(ctx, f.d, now, db.WaitingKind("other")); err == nil {
		t.Error("an unknown kind has a fingerprint")
	}
}

// The same items, the clock moved past local midnight with every age
// reading the same: the item moves from Today to This week, and the people
// fingerprint moves with it.
func TestWaitingFingerprint_SectionChangeAtMidnight(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	loc := time.FixedZone("UTC+3", 3*3600)
	before := time.Date(2026, 10, 22, 23, 50, 0, 0, loc)
	f.insertItem(t, "1000.0001", "mention", before.Add(-30*time.Minute))
	fp := func(at time.Time) string {
		t.Helper()
		s, err := WaitingFingerprint(ctx, f.d, at, db.WaitingPeople)
		if err != nil {
			t.Fatal(err)
		}
		return s
	}
	after := before.Add(20 * time.Minute)
	if a, b := rowsOf(t, waitingFields(t, f.d, before), "items")[0], rowsOf(t, waitingFields(t, f.d, after), "items")[0]; a["age"] != b["age"] || a["section"] != "today" || b["section"] != "week" {
		t.Fatalf("before %v, after %v; want the same age, today then week", a, b)
	}
	if fp(before) == fp(after) {
		t.Error("the people fingerprint kept across midnight")
	}
}

// runWaiting runs Waiting for me once and returns its one artifact.
func (f *fixture) runWaiting(t *testing.T) waitingCard {
	t.Helper()
	if run := f.runOnce(t, waitingID); run.Status != db.RunSucceeded {
		t.Fatalf("run = %+v (%s)", run, run.Error)
	}
	cards := f.waitingArtifacts(t)
	if len(cards) != 1 || cards[0].key != "waiting" || cards[0].title != "Waiting for me" {
		t.Fatalf("artifacts = %+v; want one `waiting`", cards)
	}
	return cards[0]
}

// The people items fall into Today, This week and Older, one list each
// titled with its count; a section with no items draws no list.
func TestWaitingForMe_Sections(t *testing.T) {
	for name, c := range map[string]struct {
		ages   []time.Duration
		titles []string
		rows   []int
	}{
		"all three": {
			[]time.Duration{time.Minute, 2 * time.Hour, 24 * time.Hour, 2 * 24 * time.Hour, 3 * 24 * time.Hour, 8 * 24 * time.Hour},
			[]string{"Today · 2", "This week · 3", "Older · 1"}, []int{2, 3, 2},
		},
		"no week": {
			[]time.Duration{time.Minute, 10 * 24 * time.Hour, 9 * 24 * time.Hour},
			[]string{"Today · 1", "Older · 2"}, []int{1, 3},
		},
		"week only": {
			[]time.Duration{2 * 24 * time.Hour},
			[]string{"This week · 1"}, []int{1},
		},
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			f.sync(t)
			for i, age := range c.ages {
				f.insertItem(t, fmt.Sprintf("1000.%04d", i+1), "mention", f.clock.Now().Add(-age))
			}
			card := f.runWaiting(t)
			var titles []string
			var rows []int
			for _, l := range card.lists {
				titles = append(titles, l.Title)
				rows = append(rows, len(l.Rows))
			}
			if !slices.Equal(titles, c.titles) || !slices.Equal(rows, c.rows) {
				t.Errorf("lists %v with %v rows; want %v with %v", titles, rows, c.titles, c.rows)
			}
		})
	}
}

// The Older list starts with the note row (the waiting_older ref, no
// badge) and the older items follow it, newest first; one item reads in
// the singular. At 200 older items and nothing newer, items holds 200
// older rows and the note row takes one of the list's 200 rows.
func TestWaitingForMe_OlderNoteRow(t *testing.T) {
	for name, c := range map[string]struct {
		n         int
		title     string
		listTitle string
		itemRows  int
		today     bool
	}{
		"one":  {1, "1 item is older than 7 days", "Older · 1", 1, true},
		"two":  {2, "2 items are older than 7 days", "Older · 2", 2, true},
		"full": {WaitingPeopleLimit, "200 items are older than 7 days", "Older · 200", blocks.MaxListRows - 1, false},
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			f.sync(t)
			if c.today {
				f.insertItem(t, "1000.0000", "mention", f.clock.Now().Add(-time.Hour))
			}
			for i := 1; i <= c.n; i++ {
				f.insertItem(t, fmt.Sprintf("1000.%04d", i), "mention", f.clock.Now().Add(-8*24*time.Hour-time.Duration(i)*time.Minute))
			}
			card := f.runWaiting(t)
			older := card.lists[len(card.lists)-1]
			if older.Title != c.listTitle || len(older.Rows) != 1+c.itemRows {
				t.Fatalf("last list %q with %d rows; want %q with %d", older.Title, len(older.Rows), c.listTitle, 1+c.itemRows)
			}
			note := older.Rows[0]
			if note.Title != c.title || note.Subtitle != "Nobody has followed up on them." || note.Badge != nil ||
				note.Ref == nil || note.Ref.Kind != blocks.RefWaitingOlder || note.Ref.Key != "people" {
				t.Errorf("note row = %+v (ref %+v)", note, note.Ref)
			}
			var prev int64
			for _, r := range older.Rows[1:] {
				if r.Ref == nil || r.Ref.Kind != blocks.RefInboxItem || r.Ref.ID <= prev || r.Tone != "warning" || r.Badge == nil {
					t.Fatalf("older row %+v; want older items newest first", r)
				}
				prev = r.Ref.ID
			}
		})
	}
}

// Only mail open: Waiting for me shows its one empty list, no mail row.
func TestWaitingForMe_OnlyMailOpenShowsEmpty(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.insertMail(t, "2000.0001", "a@example.com", "Hello", f.clock.Now())
	f.insertMail(t, "2000.0002", "b@example.com", "Hi", f.clock.Now().Add(-9*24*time.Hour))
	card := f.runWaiting(t)
	if len(card.lists) != 1 || len(card.lists[0].Rows) != 0 || card.lists[0].Empty != "Nobody is waiting on you" || card.lists[0].Title != "" {
		t.Errorf("lists = %+v; want one empty list", card.lists)
	}
}
