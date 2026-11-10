package builtin

import (
	"context"
	"fmt"
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
// list block.
type waitingCard struct {
	key, title string
	list       *blocks.List
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
		if err != nil || len(doc.Blocks) != 1 || doc.Blocks[0].List == nil {
			t.Fatalf("blocks %s: %v; want one list block", stored, err)
		}
		c.list = doc.Blocks[0].List
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
// with one ref row per open item, newest first, worded as the Desktop's
// message rows; the run costs no tokens.
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
	list := cards[0].list
	var ids []int64
	byID := map[int64]blocks.ListRow{}
	for _, r := range list.Rows {
		if r.Ref == nil || r.Ref.Kind != blocks.RefInboxItem {
			t.Fatalf("row %+v has no inbox_item ref", r)
		}
		ids = append(ids, r.Ref.ID)
		byID[r.Ref.ID] = r
	}
	if !slices.Equal(ids, fx.OpenIDs) {
		t.Fatalf("row refs = %v, want %v", ids, fx.OpenIDs)
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
		{15, "colleague-a@example.com — Budget review", "Budget review — please confirm the numbers", "2 h", "", "https://mail.example.com/m/15"},
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
	if len(cards) != 1 || len(cards[0].list.Rows) != 0 || cards[0].list.Empty != "Nobody is waiting on you" {
		t.Fatalf("artifacts = %+v; want one empty `waiting`", cards)
	}
	f.insertItem(t, "1000.0001", "mention", f.clock.Now())
	if run := f.runOnce(t, waitingID); run.Status != db.RunSucceeded {
		t.Fatalf("run = %+v", run)
	}
	if cards = f.waitingArtifacts(t); len(cards) != 1 || len(cards[0].list.Rows) != 1 {
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
	rows := f.waitingArtifacts(t)[0].list.Rows
	if len(rows) != 1 || rows[0].Title != "Someone" || rows[0].Subtitle != "" || rows[0].Badge.Text != "< 1 h" || rows[0].Link != "" {
		t.Errorf("rows = %+v", rows)
	}
}

// At most 200 rows, the newest.
func TestWaitingForMe_CapsAt200(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	for i := 1; i <= 201; i++ {
		f.insertItem(t, fmt.Sprintf("1000.%04d", i), "mention", f.clock.Now().Add(-time.Duration(i)*time.Minute))
	}
	if run := f.runOnce(t, waitingID); run.Status != db.RunSucceeded {
		t.Fatalf("run = %+v (%s)", run, run.Error)
	}
	rows := f.waitingArtifacts(t)[0].list.Rows
	if len(rows) != WaitingLimit || rows[0].Badge.Text != "< 1 h" {
		t.Errorf("%d rows, first %+v; want %d, the newest first", len(rows), rows[0], WaitingLimit)
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
	if len(out) != 1 || out[0].BuiltinID != waitingID || out[0].Skipped != SkippedOff {
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
	for i := 1; i <= WaitingLimit; i++ {
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
	rows := f.waitingArtifacts(t)[0].list.Rows
	if len(rows) != WaitingLimit || rows[0].Subtitle == "" || !strings.HasSuffix(rows[0].Subtitle, "…") || rows[0].Link == "" {
		t.Errorf("%d rows, first %+v; want %d rows with trimmed texts and their links", len(rows), rows[0], WaitingLimit)
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
		s, err := WaitingFingerprint(ctx, f.d, at)
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
	rows := f.waitingArtifacts(t)[0].list.Rows
	if len(rows) != 1 || rows[0].Badge != nil || rows[0].Tone != "" {
		t.Errorf("rows = %+v; want one row without a badge or tone", rows)
	}
}

// TestWaitingForMe_WebLinkKeepsOnlyLinksTheBlocksAdmit: a permalink the
// blocks would refuse is dropped so it cannot fail the whole run.
func TestWaitingForMe_WebLinkKeepsOnlyLinksTheBlocksAdmit(t *testing.T) {
	long := "https://acme.example.com/" + strings.Repeat("a", blocks.MaxLinkBytes)
	cases := map[string]string{
		"https://acme.example.com/archives/C1/p1": "https://acme.example.com/archives/C1/p1",
		"HTTP://acme.example.com/x":               "HTTP://acme.example.com/x",
		"":                                        "",
		"ftp://acme.example.com/x":                "",
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
