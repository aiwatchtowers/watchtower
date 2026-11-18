package inboxfeed

import (
	"context"
	"database/sql"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"watchtower/internal/tools"
	"watchtower/internal/tower/api"
)

// TestInboxFeedCases runs every case of the shared fixture: Build equals its
// expect (built_at blank). InboxFeedParityTests runs the Swift builders
// over the same cases. -update rewrites the expects.
func TestInboxFeedCases(t *testing.T) {
	cases := loadCases(t)
	if *update {
		rewriteCases(t, cases)
		return
	}
	names := map[string]bool{}
	for _, c := range cases {
		names[c.Name] = true
		t.Run(c.Name, func(t *testing.T) {
			got, steps := buildSteps(t, c)
			if g, w := canonical(t, got), canonical(t, c.Expect); g != w {
				t.Fatalf("feed differs from the fixture\n got: %s\nwant: %s", g, w)
			}
			for i, s := range c.Steps {
				if g, w := canonical(t, steps[i]), canonical(t, s.Expect); g != w {
					t.Fatalf("step %s: feed differs from the fixture\n got: %s\nwant: %s", s.Name, g, w)
				}
			}
			if len(c.Steps) > 0 && !c.Desktop {
				t.Errorf("a case with steps is a Desktop scenario: mark it desktop")
			}
		})
	}
	for _, want := range []string{
		"empty_install", "owner_folders_order_and_counts", "unread_artifact_counts_one",
		"artifact_rows_waiting_count_per_ref", "markdown_card_has_empty_blocks", "living_card_stamp_updated",
		"save_automation_proposal_summary", "builtin_upgrade_notice_card",
		"limit_keeps_approvals_and_waiting_first", "folder_option_narrows",
	} {
		if !names[want] {
			t.Errorf("the fixture has no case %q", want)
		}
	}
}

var testNow = time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC)

// TestBuild_IsOneReadOnlySnapshot: a write that commits between two of
// Build's reads is not seen — the folder counts and the cards agree.
func TestBuild_IsOneReadOnlySnapshot(t *testing.T) {
	d, path := seededAt(t, []string{
		"INSERT INTO automations (id, slug, scope, path, name) VALUES (1, 'a', 'personal', '/recipes/a.md', 'A')",
		"INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES (1, 1, 'manual', 'succeeded')",
		"INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, created_at) " +
			"VALUES (1, 1, 1, 'inbox', 'One', 'Body', '2026-11-16T08:00:00Z')",
	})
	writer := otherHandle(t, path)
	ctx := context.Background()
	tx, err := d.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback() }()
	// The snapshot starts at the transaction's first read.
	if _, err := readTree(ctx, tx); err != nil {
		t.Fatal(err)
	}
	// Another connection commits a second unread card mid-read.
	if _, err := writer.Exec("INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, created_at) " +
		"VALUES (2, 1, 1, 'inbox', 'Two', 'Body', '2026-11-16T09:00:00Z')"); err != nil {
		t.Fatal(err)
	}
	s, err := read(ctx, tx, testNow, nil)
	if err != nil {
		t.Fatal(err)
	}
	_ = tx.Rollback()
	feed := compose(s, Options{Now: testNow})
	if len(feed.Cards) != 1 || feed.Folders[0].Count != 1 {
		t.Fatalf("the read saw the write made after it began: %d cards, root count %d", len(feed.Cards), feed.Folders[0].Count)
	}
	// A new Build sees it, and its count agrees with its cards.
	after, err := Build(ctx, d, Options{Now: testNow})
	if err != nil {
		t.Fatal(err)
	}
	if len(after.Cards) != 2 || after.Folders[0].Count != 2 {
		t.Fatalf("a later Build: %d cards, root count %d; want 2 and 2", len(after.Cards), after.Folders[0].Count)
	}
}

// TestBuild_WritesNothing: a Build over every fixture case leaves
// data_version (read on a second handle, so any commit moves it) and the
// building connection's total_changes as they were.
func TestBuild_WritesNothing(t *testing.T) {
	ctx := context.Background()
	for _, c := range loadCases(t) {
		d, path := seededAt(t, c.Seed)
		watcher, err := otherHandle(t, path).Conn(ctx)
		if err != nil {
			t.Fatal(err)
		}
		state := func() (version, changes int64) {
			if err := watcher.QueryRowContext(ctx, "PRAGMA data_version").Scan(&version); err != nil {
				t.Fatal(err)
			}
			if err := d.QueryRowContext(ctx, "SELECT total_changes()").Scan(&changes); err != nil {
				t.Fatal(err)
			}
			return version, changes
		}
		v0, c0 := state()
		if _, err := Build(ctx, d, Options{Limit: 2, Clip: true, Now: testNow}); err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		v1, c1 := state()
		_ = watcher.Close()
		if v0 != v1 || c0 != c1 {
			t.Fatalf("%s: Build wrote: data_version %d→%d, total_changes %d→%d", c.Name, v0, v1, c0, c1)
		}
	}
}

// TestBuild_StampsAreUTCAndSourceLineHasNoTime (Review Focus 1): every
// stamp is RFC 3339 UTC ending in Z, and a source line carries the source
// only — the screen models add the time in the client's zone.
func TestBuild_StampsAreUTCAndSourceLineHasNoTime(t *testing.T) {
	tokyo := time.FixedZone("JST", 9*3600)
	for _, c := range loadCases(t) {
		d := seeded(t, c.Seed)
		feed, err := Build(context.Background(), d, Options{Now: testNow.In(tokyo)})
		if err != nil {
			t.Fatal(err)
		}
		stamps := []string{feed.BuiltAt}
		for _, card := range feed.Cards {
			stamps = append(stamps, card.Stamp)
			if card.Automation != nil && card.SourceLine != card.Automation.Name {
				t.Errorf("%s: %s source line %q is not its automation's name", c.Name, card.ID, card.SourceLine)
			}
			for _, timeish := range []string{":", "ago", "Updated", "just now"} {
				if strings.Contains(card.SourceLine, timeish) {
					t.Errorf("%s: %s source line %q carries a time", c.Name, card.ID, card.SourceLine)
				}
			}
		}
		for _, s := range stamps {
			p, err := time.Parse(time.RFC3339, s)
			if err != nil || !strings.HasSuffix(s, "Z") || p.Location() != time.UTC {
				t.Errorf("%s: stamp %q is not RFC 3339 UTC", c.Name, s)
			}
		}
	}
}

// TestClip_CutsOnARuneBoundary (Review Focus 2): a body one byte short of
// the cap followed by a two-byte rune is cut before the rune, never inside.
func TestClip_CutsOnARuneBoundary(t *testing.T) {
	body := strings.Repeat("a", ClipBytes-1) + "ё" + "tail"
	got, clipped := Clip(body, ClipBytes)
	if !clipped || !utf8.ValidString(got) || len(got) != ClipBytes-1 {
		t.Fatalf("Clip: %d bytes, clipped %v, valid %v", len(got), clipped, utf8.ValidString(got))
	}
	if same, clipped := Clip("short ё", ClipBytes); clipped || same != "short ё" {
		t.Fatalf("a body under the cap changed: %q %v", same, clipped)
	}
	// Through Build: the clipped card says so.
	d := seeded(t, []string{
		"INSERT INTO automations (id, slug, scope, path) VALUES (1, 'a', 'personal', '/recipes/a.md')",
		"INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES (1, 1, 'manual', 'succeeded')",
		"INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, created_at) " +
			"VALUES (1, 1, 1, 'inbox', 'Big', '" + body + "', '2026-11-16T08:00:00Z')",
	})
	feed, err := Build(context.Background(), d, Options{Clip: true, Now: testNow})
	if err != nil {
		t.Fatal(err)
	}
	c := feed.Cards[0]
	if !c.BodyClipped || !utf8.ValidString(c.Body) || len(c.Body) > ClipBytes {
		t.Fatalf("clipped card: %d bytes, body_clipped %v", len(c.Body), c.BodyClipped)
	}
	unclipped, err := Build(context.Background(), d, Options{Now: testNow})
	if err != nil {
		t.Fatal(err)
	}
	if unclipped.Cards[0].BodyClipped || unclipped.Cards[0].Body != body {
		t.Fatal("without Clip the body must be whole")
	}
}

// TestBuild_OversizeBlocksBecomeANotice (Review Focus 2): a card whose
// block document is past MaxBlocksBytes is a notice card with no blocks,
// never a broken record.
func TestBuild_OversizeBlocksBecomeANotice(t *testing.T) {
	big := `{"v":1,"blocks":[{"type":"text","text":"` + strings.Repeat("x", MaxBlocksBytes) + `"}]}`
	d := seeded(t, []string{
		"INSERT INTO automations (id, slug, scope, path, name) VALUES (1, 'a', 'personal', '/recipes/a.md', 'A')",
		"INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES (1, 1, 'manual', 'succeeded')",
		"INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, blocks_json, content_hash, created_at) " +
			"VALUES (1, 1, 1, 'inbox', 'Huge', 'xxx', '" + big + "', 'h', '2026-11-16T08:00:00Z')",
		"INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, blocks_json, created_at) " +
			`VALUES (2, 1, 1, 'inbox', 'Small', 'ok', '{"v":1,"blocks":[]}', '2026-11-16T07:00:00Z')`,
	})
	feed, err := Build(context.Background(), d, Options{Now: testNow})
	if err != nil {
		t.Fatal(err)
	}
	byID := map[string]api.Card{}
	for _, c := range feed.Cards {
		byID[c.ID] = c
	}
	huge := byID["o1"]
	if huge.CardKind != api.CardNotice || huge.Blocks != "" || huge.Body != TooLargeSentence || huge.Title != "Huge" {
		t.Fatalf("the oversize card: %+v", huge)
	}
	if huge.ContentHash != "h" {
		t.Fatal("the notice keeps the content hash its read mark is guarded by")
	}
	if small := byID["o2"]; small.CardKind != api.CardArtifact || small.Blocks == "" {
		t.Fatalf("a card within the cap changed: %+v", small)
	}
}

// TestCardIDs_RoundTripAndNeverCollide: every id kind parses back to what
// made it, ids of different kinds never collide, and malformed ids fail.
func TestCardIDs_RoundTripAndNeverCollide(t *testing.T) {
	type parsed struct {
		kind string
		num  int64
		date string
	}
	cases := map[string]parsed{
		OutputCardID(7):             {KindOutput, 7, ""},
		ActionCardID(7):             {KindAction, 7, ""},
		ReminderCardID(7):           {KindReminder, 7, ""},
		NoticeCardID(7):             {KindNotice, 7, ""},
		BriefCardID("2026-11-16"):   {KindBrief, 0, "2026-11-16"},
		TracksCardID:                {KindTracks, 0, ""},
		IdeasCardID:                 {KindIdeas, 0, ""},
		ThreadBriefCardID(7):        {KindThreadBrief, 7, ""},
		MessagesCardID:              {KindMessages, 0, ""},
		OutputCardID(1234567890123): {KindOutput, 1234567890123, ""},
	}
	if len(cases) != 10 {
		t.Fatalf("two kinds made the same id: %d distinct of 10", len(cases))
	}
	for id, want := range cases {
		kind, num, date, err := ParseCardID(id)
		if err != nil || (parsed{kind, num, date}) != want {
			t.Errorf("ParseCardID(%q) = %q %d %q %v, want %+v", id, kind, num, date, err, want)
		}
	}
	for _, bad := range []string{"", "o", "o0", "o-1", "o01", "x7", "brief-", "brief-2026-13-01", "o7a", "tracks2"} {
		if _, _, _, err := ParseCardID(bad); err == nil {
			t.Errorf("ParseCardID(%q) accepted a malformed id", bad)
		}
	}
}

// TestBuild_ArgsDisplayOnlyOnTheClippedFeed (mobile Inbox spec §12.1): an
// approval's display args go to the hub's clipped feed only, cut at
// ArgsDisplayClipBytes with ArgsComplete cleared; the Mac's feed carries
// none. The digest stays over the stored bytes.
func TestBuild_ArgsDisplayOnlyOnTheClippedFeed(t *testing.T) {
	wide := strings.Repeat("日本", 1900) // 3800 characters, 11 400 bytes
	d := seeded(t, []string{
		`INSERT INTO agent_actions (id, tool, args_json, reason, status, created_at)
			VALUES (1, 'create_jira_issue', '{"summary":"` + wide + `"}', 'r', 'pending', '2026-11-16T09:00:00Z')`,
		`INSERT INTO agent_actions (id, tool, args_json, reason, status, created_at)
			VALUES (2, 'create_jira_issue', '{"summary":"x"}', 'r', 'pending', '2026-11-16T09:01:00Z')`,
	})
	approvalOf := func(f api.Feed, id string) *api.Approval {
		for _, c := range f.Cards {
			if c.ID == id {
				return c.Approval
			}
		}
		t.Fatalf("no card %s", id)
		return nil
	}
	clipped, err := Build(context.Background(), d, Options{Clip: true, Now: testNow})
	if err != nil {
		t.Fatal(err)
	}
	big, small := approvalOf(clipped, "a1"), approvalOf(clipped, "a2")
	if len(big.ArgsDisplay) > ArgsDisplayClipBytes || big.ArgsComplete || !utf8.ValidString(big.ArgsDisplay) || big.ArgsDisplay == "" {
		t.Fatalf("wide args: %d bytes, complete %v", len(big.ArgsDisplay), big.ArgsComplete)
	}
	if !small.ArgsComplete || !strings.Contains(small.ArgsDisplay, `"summary": "x"`) {
		t.Fatalf("small args: %q complete %v", small.ArgsDisplay, small.ArgsComplete)
	}
	if big.ArgsSHA256 != tools.ArgsSHA256(`{"summary":"`+wide+`"}`) {
		t.Fatal("the digest is not over the stored bytes")
	}
	mac, err := Build(context.Background(), d, Options{Now: testNow})
	if err != nil {
		t.Fatal(err)
	}
	if a := approvalOf(mac, "a1"); a.ArgsDisplay != "" || a.ArgsComplete {
		t.Fatalf("the Mac's feed carries display args: %d bytes", len(a.ArgsDisplay))
	}
}

// TestBuild_ClippedSlackDraftStillNeedsItsWorkspace: a Slack draft with no
// workspace chosen whose multibyte text runs past ArgsDisplayClipBytes keeps
// needs_workspace, decided from the whole stored args, so the phone offers
// no Approve the hub would refuse; a draft with its target pinned does not.
func TestBuild_ClippedSlackDraftStillNeedsItsWorkspace(t *testing.T) {
	text := strings.Repeat("日本語", 1300) // 3900 characters, 11 700 bytes
	d := seeded(t, []string{
		`INSERT INTO agent_actions (id, tool, args_json, reason, status, created_at)
			VALUES (1, 'send_slack_message', '{"text":"` + text + `","candidates":[{"account_id":1,"workspace":"acme","label":"#eng"},` +
			`{"account_id":2,"workspace":"example","label":"#eng"}]}', 'r', 'pending', '2026-11-16T09:00:00Z')`,
		`INSERT INTO agent_actions (id, tool, args_json, reason, status, created_at)
			VALUES (2, 'send_slack_message', '{"text":"hi","target":{"account_id":1,"workspace":"acme","label":"#eng"}}',
			'r', 'pending', '2026-11-16T09:01:00Z')`,
	})
	feed, err := Build(context.Background(), d, Options{Clip: true, Now: testNow})
	if err != nil {
		t.Fatal(err)
	}
	byID := map[string]*api.Approval{}
	for _, c := range feed.Cards {
		byID[c.ID] = c.Approval
	}
	draft, pinned := byID["a1"], byID["a2"]
	if draft == nil || pinned == nil {
		t.Fatal("missing cards")
	}
	if draft.ArgsComplete || len(draft.ArgsDisplay) > ArgsDisplayClipBytes {
		t.Fatalf("the draft's display args were not clipped: %d bytes", len(draft.ArgsDisplay))
	}
	if !draft.NeedsWorkspace {
		t.Fatal("a clipped draft with no workspace lost needs_workspace")
	}
	if pinned.NeedsWorkspace {
		t.Fatal("a pinned send needs no workspace")
	}
}
