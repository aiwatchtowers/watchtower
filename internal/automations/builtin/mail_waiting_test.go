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

// waitingSplitFixture is the people/mail fixture the Desktop reads too.
const waitingSplitFixture = "../../inbox/testdata/waiting_split.json"

// mailCard is the Mail waiting artifact as stored: its key, title, its
// stored blocks and, in order, the header text (if any), the one list and
// the closing text (if any).
type mailCard struct {
	key, title, stored string
	header, closing    string
	list               *blocks.List
}

// mailArtifact reads Mail waiting's one inbox output.
func (f *fixture) mailArtifact(t *testing.T) mailCard {
	t.Helper()
	rows, err := f.d.Query(`SELECT output_key, title, blocks_json FROM automation_outputs
		WHERE automation_id = ? AND kind = 'inbox' ORDER BY id`, f.rowOf(t, MailWaitingID).ID)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var cards []mailCard
	for rows.Next() {
		var c mailCard
		if err := rows.Scan(&c.key, &c.title, &c.stored); err != nil {
			t.Fatal(err)
		}
		doc, err := blocks.Decode(c.stored)
		if err != nil || doc == nil {
			t.Fatalf("blocks %s: %v", c.stored, err)
		}
		for _, b := range doc.Blocks {
			switch {
			case b.List != nil && c.list == nil:
				c.list = b.List
			case b.Text != nil && c.list == nil && c.header == "":
				c.header = b.Text.Markdown
			case b.Text != nil && c.list != nil && c.closing == "":
				c.closing = b.Text.Markdown
			default:
				t.Fatalf("blocks %.300s: want [text] list [text]", c.stored)
			}
		}
		if c.list == nil {
			t.Fatalf("blocks %.300s: no list", c.stored)
		}
		cards = append(cards, c)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if len(cards) != 1 || cards[0].key != "mail" || cards[0].title != "Mail waiting" {
		t.Fatalf("artifacts = %+v; want one `mail` titled Mail waiting", cards)
	}
	return cards[0]
}

// runMail runs Mail waiting once, wants it succeeded, and returns its
// artifact.
func (f *fixture) runMail(t *testing.T) mailCard {
	t.Helper()
	run := f.runOnce(t, MailWaitingID)
	if run.Status != db.RunSucceeded {
		t.Fatalf("run = %s (%s); want succeeded", run.Status, run.Error)
	}
	if run.InputTokens != 0 || run.OutputTokens != 0 {
		t.Errorf("run spent %d+%d tokens; want none", run.InputTokens, run.OutputTokens)
	}
	return f.mailArtifact(t)
}

func TestMailWaiting_ShippedRecipeHasNoLLM(t *testing.T) {
	e, ok := Lookup(MailWaitingID)
	if !ok {
		t.Fatal("no mail-waiting built-in")
	}
	r, err := ParseShipped(e)
	if err != nil {
		t.Fatal(err)
	}
	if n := automations.LLMCallSites(r.Script); n != 0 {
		t.Errorf("LLMCallSites = %d, want 0", n)
	}
	if r.Name != "Mail waiting" || r.Artifacts != automations.ArtifactsLiving || r.Trigger.Sync != string(SlotWaitingForMe) || r.Concurrency != 1 {
		t.Errorf("recipe = name %q, artifacts %q, sync %q, concurrency %d", r.Name, r.Artifacts, r.Trigger.Sync, r.Concurrency)
	}
	if e.Name != "Mail waiting" || e.Slot != SlotWaitingForMe || e.DefaultFolder != RootFolder || !e.RunNow ||
		!slices.Equal(e.FeatureIDs, []string{"secretary-inbox"}) ||
		!slices.Equal(e.Primitives, []string{automations.PrimitiveAttentionWaiting}) || len(e.Prompts) != 0 {
		t.Errorf("entry = %+v", e)
	}
	if !slices.Equal(e.Reads, []string{"The mail attention detection found"}) ||
		!slices.Equal(e.Does, []string{
			"Groups the mail that waits on you by sender, the busiest first",
			"Updates the list after every sync; muted senders are left out",
			"Uses no AI",
		}) ||
		!slices.Equal(e.Sends, []string{"One Mail waiting list in your Inbox"}) ||
		e.When(nil) != "After every sync, while attention detection is on" {
		t.Errorf("card copy = reads %q does %q sends %q when %q", e.Reads, e.Does, e.Sends, e.When(nil))
	}
}

// Over the shared fixture: one row per open, unmuted sender in the
// fixture's order, each a mail_sender ref with its counts and newest
// subject; the muted sender is absent and the sender with no address is
// "Unknown sender" with no ref.
func TestMailWaiting_OneRowPerOpenSender(t *testing.T) {
	f := newFixture(t)
	fx := db.SeedTestWaitingSplitFixture(t, f.d, waitingSplitFixture)
	f.clock.Set(fx.Now)
	f.sync(t)
	card := f.runMail(t)
	want := fx.Expected.Senders
	rows := card.list.Rows
	if len(rows) != len(want) {
		t.Fatalf("%d rows %+v; want %d", len(rows), rows, len(want))
	}
	for i, w := range want {
		r := rows[i]
		title := w.Address
		if title == "" {
			title = "Unknown sender"
		}
		sub := fmt.Sprintf("%d open · %d today · %s", w.Open, w.Today, w.Subject)
		if r.Title != title || r.Subtitle != sub || r.Badge == nil || r.Badge.Text != fmt.Sprint(w.Open) {
			t.Errorf("row %d = title %q subtitle %q badge %+v; want %q %q %d", i, r.Title, r.Subtitle, r.Badge, title, sub, w.Open)
		}
		switch {
		case w.Address == "" && r.Ref != nil:
			t.Errorf("row %d: the empty address has ref %+v; want none", i, r.Ref)
		case w.Address != "" && (r.Ref == nil || r.Ref.Kind != blocks.RefMailSender || r.Ref.Key != w.Address):
			t.Errorf("row %d: ref %+v; want mail_sender %q", i, r.Ref, w.Address)
		}
		if strings.Contains(r.Title, "news@") {
			t.Errorf("row %d is the muted sender", i)
		}
	}
	if rows[0].Link != "https://mail.example.com/m/20" {
		t.Errorf("first row link = %q; want the newest item's permalink", rows[0].Link)
	}
	if want := "100% of this mail comes from 6 senders."; card.header != want {
		t.Errorf("header = %q; want %q", card.header, want)
	}
	if card.closing != "" {
		t.Errorf("closing = %q; want none", card.closing)
	}
}

// A raw From address the ref would refuse is still listed and counted,
// with no ref, and the run succeeds; an address longer than a row title
// is clipped to it.
func TestMailWaiting_UnactionableSenderListedWithoutRef(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	now := f.clock.Now()
	long := strings.Repeat("a", 288) + "@example.com"   // 300 bytes: past a ref, still a title
	longer := strings.Repeat("b", 388) + "@example.com" // 400 bytes: past a row title
	raw := []string{`"Name" <a@example.com>`, "a@@example.com", "a b@example.com", long, longer, "a&b@example.com", "ok@example.com"}
	for i, s := range raw {
		f.insertMail(t, fmt.Sprintf("2000.%04d", i), s, "Hello", now.Add(-time.Duration(i)*time.Minute))
	}
	card := f.runMail(t)
	if len(card.list.Rows) != len(raw) {
		t.Fatalf("%d rows; want %d", len(card.list.Rows), len(raw))
	}
	for _, r := range card.list.Rows {
		actionable := r.Title == "ok@example.com"
		if (r.Ref != nil) != actionable || r.Subtitle != "1 open · 0 today · Hello" && r.Subtitle != "1 open · 1 today · Hello" {
			t.Errorf("row %.60q = ref %+v subtitle %q; want a ref only for ok@example.com", r.Title, r.Ref, r.Subtitle)
		}
		if n := len([]rune(r.Title)); n > blocks.MaxRowTitleChars {
			t.Errorf("row title has %d runes", n)
		}
	}
	if want := fmt.Sprintf("100%% of this mail comes from %d senders.", len(raw)); card.header != want {
		t.Errorf("header = %q; want %q", card.header, want)
	}
}

// The header names the top ten senders' share; with no mail there is no
// header and the list is empty.
func TestMailWaiting_HeaderShare(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	card := f.runMail(t)
	if card.header != "" || len(card.list.Rows) != 0 || card.list.Empty != "No mail is waiting on you" || card.closing != "" {
		t.Fatalf("empty card = %+v; want an empty list only", card)
	}
	now := f.clock.Now()
	// s01 has 10 open, s02…s12 one each: 21 open, the top ten 19.
	for i := 1; i <= 10; i++ {
		f.insertMail(t, fmt.Sprintf("2000.%04d", i), "s01@example.com", "Hello", now.Add(-time.Duration(i)*time.Minute))
	}
	for i := 2; i <= 12; i++ {
		f.insertMail(t, fmt.Sprintf("3000.%04d", i), fmt.Sprintf("s%02d@example.com", i), "Hello", now.Add(-time.Duration(i)*time.Hour))
	}
	card = f.runMail(t)
	if want := "90% of this mail comes from 10 senders."; card.header != want {
		t.Errorf("header = %q; want %q", card.header, want)
	}
	if len(card.list.Rows) != 12 || card.list.Rows[0].Title != "s01@example.com" || card.list.Rows[0].Badge.Text != "10" {
		t.Errorf("rows = %+v; want 12, s01 first with 10 open", card.list.Rows)
	}
}

// One sender: the header says "1 sender".
func TestMailWaiting_HeaderOneSender(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.insertMail(t, "2000.0001", "a@example.com", "", f.clock.Now())
	card := f.runMail(t)
	if want := "100% of this mail comes from 1 sender."; card.header != want {
		t.Errorf("header = %q; want %q", card.header, want)
	}
	// An empty subject leaves only the counts.
	if r := card.list.Rows; len(r) != 1 || r[0].Subtitle != "1 open · 1 today" {
		t.Errorf("rows = %+v; want one without a subject", r)
	}
}

// 210 senders: 200 rows and a closing "10 more senders".
func TestMailWaiting_MoreSendersLine(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	now := f.clock.Now()
	for i := 1; i <= 210; i++ {
		f.insertMail(t, fmt.Sprintf("2000.%04d", i), fmt.Sprintf("s%03d@example.com", i), "Hello", now.Add(-time.Duration(i)*time.Minute))
	}
	card := f.runMail(t)
	if len(card.list.Rows) != WaitingSendersLimit {
		t.Fatalf("%d rows; want %d", len(card.list.Rows), WaitingSendersLimit)
	}
	if card.closing != "10 more senders" {
		t.Errorf("closing = %q; want \"10 more senders\"", card.closing)
	}
}

// 200 senders whose addresses are the longest a ref admits, each with a
// long subject and link: the stored document stays under the blocks' cap,
// every row keeps its title and ref, and the run succeeds.
func TestMailWaiting_ByteCapWithLongAddresses(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	now := f.clock.Now()
	for i := 1; i <= 205; i++ {
		addr := fmt.Sprintf("%03dx", i) + strings.Repeat("ж", 119) + "@example.com" // 254 bytes
		head := fmt.Sprintf("https://mail.example.com/m/%04d/", i)
		for j := 0; j < 2; j++ {
			if _, err := f.d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, snippet, permalink, created_at)
				VALUES ('gmail', ?, ?, 'email_received', ?, ?, ?)`, fmt.Sprintf("2000.%04d.%d", i, j), addr,
				strings.Repeat("Ж", 400)+" — body", head+strings.Repeat("a", blocks.MaxLinkBytes-len(head)),
				now.Add(-time.Duration(i)*time.Minute).UTC().Format(time.RFC3339)); err != nil {
				t.Fatal(err)
			}
		}
	}
	card := f.runMail(t)
	if n := len(card.stored); n > blocks.MaxBlocksBytes {
		t.Errorf("stored blocks are %d bytes; the cap is %d", n, blocks.MaxBlocksBytes)
	}
	if len(card.list.Rows) != WaitingSendersLimit {
		t.Fatalf("%d rows; want %d", len(card.list.Rows), WaitingSendersLimit)
	}
	for i, r := range card.list.Rows {
		if r.Ref == nil || r.Ref.Key != r.Title || len(r.Title) != 254 || !strings.HasPrefix(r.Subtitle, "2 open · ") {
			t.Fatalf("row %d = %.80v; want its whole address as title and ref, and its counts", i, r)
		}
	}
	if card.closing != "5 more senders" {
		t.Errorf("closing = %q; want \"5 more senders\"", card.closing)
	}
}

// Attention detection off: the slot skips both its built-ins before any
// read and writes no Mail waiting run (FEAT-01).
func TestMailWaiting_SkippedWhenDetectionOff(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.cfg.Inbox.Enabled = false
	out := f.runner.RunSlot(context.Background(), SlotWaitingForMe)
	if len(out) != 2 || out[1].BuiltinID != MailWaitingID || out[1].Skipped != SkippedOff {
		t.Fatalf("slot = %+v; want mail-waiting skipped off", out)
	}
	runs, err := f.d.ListAutomationRuns(f.rowOf(t, MailWaitingID).ID, 0)
	if err != nil || len(runs) != 0 {
		t.Errorf("runs = %+v, %v; want none", runs, err)
	}
}
