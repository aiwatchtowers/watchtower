package sources

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"watchtower/internal/automations/blocks"
	"watchtower/internal/db"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources/inboxlegacy"
	"watchtower/internal/hub/wire"
	"watchtower/internal/inboxfeed"
	"watchtower/internal/policy"
	"watchtower/internal/tower/api"
)

// inboxCase is a case of inboxfeed's shared feed fixture.
type inboxCase struct {
	Name             string          `json:"name"`
	Now              string          `json:"now"`
	Seed             []string        `json:"seed"`
	Opts             api.FeedRequest `json:"opts"`
	DisabledFeatures []string        `json:"disabled_features"`
	Expect           api.Feed        `json:"expect"`
}

func inboxCases(t *testing.T) []inboxCase {
	t.Helper()
	raw, err := os.ReadFile("../../../inboxfeed/testdata/inbox_feed_cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []inboxCase
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatal(err)
	}
	return cases
}

// inboxItems runs both Inbox kinds once (one cycle) and returns their items
// by record id.
func inboxItems(t *testing.T, srcs []hubslices.Source) (folders, cards map[string][]byte) {
	t.Helper()
	if len(srcs) != 2 || srcs[0].Kind() != hubslices.KindInboxFolder || srcs[1].Kind() != hubslices.KindInboxCard {
		t.Fatalf("sources %v", srcs)
	}
	read := func(s hubslices.Source) map[string][]byte {
		items, err := s.Items(context.Background())
		if err != nil {
			t.Fatalf("%s: %v", s.Kind(), err)
		}
		out := map[string][]byte{}
		for _, it := range items {
			if _, dup := out[it.ID]; dup {
				t.Fatalf("%s: record %s twice", s.Kind(), it.ID)
			}
			out[it.ID] = it.Payload
		}
		return out
	}
	return read(srcs[0]), read(srcs[1])
}

func marshalWire(t *testing.T, v any) []byte {
	t.Helper()
	b, err := wire.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// TestInboxSource_RecordsMatchTheGoGolden: over the feed fixture, one record
// per folder (with its cut count) and one per card, each the fixture's
// folder or card; a legacy card carries its typed section and its
// projected document.
func TestInboxSource_RecordsMatchTheGoGolden(t *testing.T) {
	ran := 0
	for _, c := range inboxCases(t) {
		if c.Opts.Folder != nil || c.Opts.Limit != 0 || c.Opts.Day != "" {
			continue // a request the phone never sends
		}
		ran++
		t.Run(c.Name, func(t *testing.T) {
			now, err := time.Parse(time.RFC3339, c.Now)
			if err != nil {
				t.Fatal(err)
			}
			d := db.OpenTestDB(t)
			for _, stmt := range c.Seed {
				exec(t, d, stmt)
			}
			build := func(ctx context.Context, o inboxfeed.Options) (api.Feed, error) {
				o.DisabledFeatures = c.DisabledFeatures
				return inboxfeed.Build(ctx, d, o)
			}
			folders, cards := inboxItems(t, InboxSource(build, func() time.Time { return now }))

			if len(folders) != len(c.Expect.Folders) || len(cards) != len(c.Expect.Cards) {
				t.Fatalf("%d folders, %d cards; want %d, %d", len(folders), len(cards), len(c.Expect.Folders), len(c.Expect.Cards))
			}
			for _, f := range c.Expect.Folders {
				ids := []string{}
				for _, card := range c.Expect.Cards {
					if card.FolderID == f.ID {
						ids = append(ids, card.ID)
					}
				}
				want := marshalWire(t, inboxFolderRecord{Folder: f, CardIDs: ids})
				if got := folders[strconv.FormatInt(f.ID, 10)]; string(got) != string(want) {
					t.Errorf("folder %d:\n got %s\nwant %s", f.ID, got, want)
				}
			}
			for _, card := range c.Expect.Cards {
				if card.Legacy != nil {
					doc, err := inboxlegacy.Project(*card.Legacy)
					if err != nil {
						t.Fatal(err)
					}
					card.Blocks = doc
				}
				if got, want := cards[card.ID], marshalWire(t, card); string(got) != string(want) {
					t.Errorf("card %s:\n got %s\nwant %s", card.ID, got, want)
				}
			}
		})
	}
	if ran < 10 {
		t.Fatalf("only %d fixture cases ran", ran)
	}
}

// TestInboxSource_LimitAndClipOnThePhone: the feed is built as the phone
// reads it (Limit 300, Clip), and the cut count rides on its folder.
func TestInboxSource_LimitAndClipOnThePhone(t *testing.T) {
	now := time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC)
	var got []inboxfeed.Options
	build := func(_ context.Context, o inboxfeed.Options) (api.Feed, error) {
		got = append(got, o)
		return api.Feed{V: 1, Folders: []api.Folder{{ID: 1, Kind: api.FolderRoot}}, Cards: []api.Card{},
			More: []api.FolderMore{{FolderID: 1, Count: 7}}}, nil
	}
	folders, _ := inboxItems(t, InboxSource(build, func() time.Time { return now }))
	if len(got) != 1 {
		t.Fatalf("%d builds for one cycle, want 1", len(got))
	}
	if o := got[0]; o.Limit != PhoneInboxLimit || PhoneInboxLimit != 300 || !o.Clip || !o.Now.Equal(now) || o.Folder != nil {
		t.Fatalf("options %+v", o)
	}
	var rec struct {
		More int `json:"more"`
	}
	if err := json.Unmarshal(folders["1"], &rec); err != nil || rec.More != 7 {
		t.Fatalf("folder record %s (%v)", folders["1"], err)
	}
}

// TestInboxSource_FailedBuildKeepsTheLastRecords: a failed build fails both
// kinds (the publisher then keeps their records and logs the class); the
// next cycle builds again.
func TestInboxSource_FailedBuildKeepsTheLastRecords(t *testing.T) {
	fail := true
	builds := 0
	build := func(context.Context, inboxfeed.Options) (api.Feed, error) {
		builds++
		if fail {
			return api.Feed{}, errors.New("database is locked")
		}
		return api.Feed{V: 1, Folders: []api.Folder{{ID: 1}}, Cards: []api.Card{{ID: "o1"}}}, nil
	}
	srcs := InboxSource(build, nil)
	for _, s := range srcs {
		if items, err := s.Items(context.Background()); err == nil {
			t.Fatalf("%s: a failed build answered %d items", s.Kind(), len(items))
		}
	}
	fail = false
	folders, cards := inboxItems(t, srcs)
	if len(folders) != 1 || len(cards) != 1 {
		t.Fatalf("after recovery %d folders, %d cards", len(folders), len(cards))
	}
	if builds != 3 {
		t.Errorf("%d builds, want 3 (two failed, one shared)", builds)
	}
	// A new cycle reads the database again.
	inboxItems(t, srcs)
	if builds != 4 {
		t.Errorf("%d builds after a second cycle, want 4", builds)
	}
}

// TestInboxSource_PolicyWorkbenchOnlyPublishesNoInboxKinds (POLICY-03):
// workbench_only builds no Inbox source and its kinds are outside the
// restricted set, so the hub's switch deletes their records.
func TestInboxSource_PolicyWorkbenchOnlyPublishesNoInboxKinds(t *testing.T) {
	for _, k := range []hubslices.Kind{hubslices.KindInboxFolder, hubslices.KindInboxCard} {
		if slices.Contains(registryKinds(t, policy.MobileWorkbenchOnly), string(k)) {
			t.Errorf("workbench_only builds %s", k)
		}
		if slices.Contains(WorkbenchOnlyKinds, k) {
			t.Errorf("%s is in WorkbenchOnlyKinds: a switch to workbench_only would keep its records", k)
		}
		if !slices.Contains(registryKinds(t, policy.MobileAllowed), string(k)) {
			t.Errorf("allowed does not build %s", k)
		}
	}
}

// TestInboxSource_EveryRecordUnder900KB: a big Inbox (huge bodies, many long
// ideas and tracks) still seals every record under the envelope cap.
func TestInboxSource_EveryRecordUnder900KB(t *testing.T) {
	d := db.OpenTestDB(t)
	long := func(n int) string {
		return "substr(replace(hex(zeroblob(" + strconv.Itoa(n) + ")), '0', 'w'), 1, " + strconv.Itoa(n) + ")"
	}
	exec(t, d, `INSERT INTO automations (id, slug, scope, path, name, enabled, disabled_reason, origin) VALUES (1, 'big', 'personal', '/recipes/big.md', 'Big', 1, '', 'owner')`)
	exec(t, d, `INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES (1, 1, 'manual', 'succeeded')`)
	exec(t, d, `WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 40)
		INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, priority, created_at, blocks_json, output_key, content_hash, written_at, changed_at)
		SELECT i, 1, 1, 'inbox', `+long(2000)+`, `+long(2_000_000)+`, 'medium', '2026-11-16T10:00:00Z', '', NULL, 'h' || i, '2026-11-16T10:00:00Z', '2026-11-16T10:00:00Z' FROM n`)
	exec(t, d, `WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 3000)
		INSERT INTO ideas (id, kind, title, essence, status, updated_at) SELECT i, 'idea', `+long(3000)+`, `+long(20000)+`, 'proposed', '2026-11-16T07:00:00Z' FROM n`)
	exec(t, d, `WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 3000)
		INSERT INTO tracks (id, text, priority, updated_at) SELECT i, `+long(5000)+`, 'high', '2026-11-16T09:00:00Z' FROM n`)
	build := func(ctx context.Context, o inboxfeed.Options) (api.Feed, error) { return inboxfeed.Build(ctx, d, o) }
	now := time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC)
	folders, cards := inboxItems(t, InboxSource(build, func() time.Time { return now }))
	if len(cards) < 40 || cards["ideas"] == nil || cards["tracks"] == nil {
		t.Fatalf("%d cards, ideas %v, tracks %v", len(cards), cards["ideas"] != nil, cards["tracks"] != nil)
	}
	for _, id := range []string{"ideas", "tracks"} {
		var c api.Card
		if err := json.Unmarshal(cards[id], &c); err != nil || c.Blocks == "" {
			t.Fatalf("%s card has no document (%v)", id, err)
		}
	}
	const budget = 900_000 - 1024 // the envelope cap less its header, signature and padding
	for name, all := range map[string]map[string][]byte{"inbox_folder": folders, "inbox_card": cards} {
		for id, p := range all {
			if len(p) > budget {
				t.Errorf("%s-%s is %d bytes", name, id, len(p))
			}
		}
	}
}

// TestInboxSource_PlanItemsKeepTheirUTCTimes: a Morning brief card carries
// its typed plan items with their UTC start and end (the phone draws them in
// its own zone), and its document writes no clock time.
func TestInboxSource_PlanItemsKeepTheirUTCTimes(t *testing.T) {
	d := db.OpenTestDB(t)
	exec(t, d, `INSERT INTO email_accounts (id, provider, email_address) VALUES (1, 'imap', 'owner@example.com')`)
	exec(t, d, `INSERT INTO day_plans (id, user_id, plan_date, generated_at) VALUES (1, 'U1', '2026-11-16', '2026-11-16T07:00:00Z')`)
	exec(t, d, `INSERT INTO day_plan_items (id, day_plan_id, kind, source_type, title, start_time, end_time, status, order_index)
		VALUES (1, 1, 'timeblock', 'manual', 'Standup', '2026-11-16T09:30:00Z', '2026-11-16T09:45:00Z', 'pending', 1)`)
	build := func(ctx context.Context, o inboxfeed.Options) (api.Feed, error) { return inboxfeed.Build(ctx, d, o) }
	now := time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC)
	_, cards := inboxItems(t, InboxSource(build, func() time.Time { return now }))
	var c api.Card
	if err := json.Unmarshal(cards["brief-2026-11-16"], &c); err != nil {
		t.Fatalf("brief card %s: %v", cards["brief-2026-11-16"], err)
	}
	if c.Legacy == nil || len(c.Legacy.Items) != 1 {
		t.Fatalf("legacy %+v", c.Legacy)
	}
	if it := c.Legacy.Items[0]; it.Stamp != "2026-11-16T09:30:00Z" || it.End != "2026-11-16T09:45:00Z" {
		t.Fatalf("item %+v, want its UTC start and end", it)
	}
	doc, err := blocks.Decode(c.Blocks)
	if err != nil {
		t.Fatal(err)
	}
	for _, b := range doc.Blocks {
		if b.List == nil {
			continue
		}
		for _, r := range b.List.Rows {
			if r.Badge != nil || strings.Contains(r.Title+r.Subtitle, ":") {
				t.Errorf("plan row %+v carries a clock time", r)
			}
		}
	}
}

// TestInboxSource_AnOversizedCardFallsBack: an approval whose summary and
// error run to megabytes is published as a too-large notice; the other
// cards and the kind go on.
func TestInboxSource_AnOversizedCardFallsBack(t *testing.T) {
	huge := strings.Repeat("x", 2_000_000)
	build := func(context.Context, inboxfeed.Options) (api.Feed, error) {
		return api.Feed{V: 1, Folders: []api.Folder{{ID: 1}}, Cards: []api.Card{
			{ID: "a1", FolderID: 1, CardKind: api.CardApprovalNative, Title: strings.Repeat("t", 500), Stamp: "2026-11-16T10:00:00Z",
				Unread: true, Priority: "high", ContentHash: "sha", Actions: []api.CardAction{}, RefFacts: []api.RefFacts{},
				Approval: &api.Approval{Tool: "send", Summary: huge, Error: huge}},
			{ID: "o2", FolderID: 1, CardKind: api.CardArtifact, Title: "small", Actions: []api.CardAction{}, RefFacts: []api.RefFacts{}},
		}}, nil
	}
	_, cards := inboxItems(t, InboxSource(build, nil))
	if len(cards) != 2 || cards["o2"] == nil {
		t.Fatalf("cards %d", len(cards))
	}
	if n := len(cards["a1"]); n > inboxRecordBudget {
		t.Fatalf("fallback is %d bytes", n)
	}
	var c api.Card
	if err := json.Unmarshal(cards["a1"], &c); err != nil {
		t.Fatal(err)
	}
	if c.CardKind != api.CardNotice || c.Approval != nil || c.Body != inboxfeed.TooLargeSentence ||
		c.ContentHash != "sha" || c.FolderID != 1 || !c.Unread || c.Priority != "high" || len([]rune(c.Title)) != fallbackTitleChars {
		t.Fatalf("fallback %+v", c)
	}
}

// TestInboxSource_AnOldBuildIsNotShared: a kind built alone (a retry) is not
// served to the other kind later: that one builds again.
func TestInboxSource_AnOldBuildIsNotShared(t *testing.T) {
	now := time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC)
	builds := 0
	build := func(context.Context, inboxfeed.Options) (api.Feed, error) {
		builds++
		return api.Feed{V: 1, Folders: []api.Folder{}, Cards: []api.Card{}}, nil
	}
	srcs := InboxSource(build, func() time.Time { return now })
	if _, err := srcs[1].Items(context.Background()); err != nil {
		t.Fatal(err)
	}
	now = now.Add(time.Minute)
	if _, err := srcs[0].Items(context.Background()); err != nil {
		t.Fatal(err)
	}
	if builds != 2 {
		t.Fatalf("%d builds, want 2: a minute-old feed was shared", builds)
	}
}

// TestInboxSource_FoldersCarryTheirCardOrder: the replica keeps no publish
// order, so each inbox_folder record lists its cards' ids in the feed's
// order, and card records stay order-free: a new card at the top changes only
// its own record and its folder's.
func TestInboxSource_FoldersCarryTheirCardOrder(t *testing.T) {
	cards := []api.Card{{ID: "a2", FolderID: 2}, {ID: "o9", FolderID: 1}, {ID: "o1", FolderID: 1}}
	build := func(context.Context, inboxfeed.Options) (api.Feed, error) {
		return api.Feed{V: 1, Folders: []api.Folder{{ID: 1, Kind: api.FolderRoot}, {ID: 2, Kind: api.FolderApprovals}, {ID: 3}},
			Cards: append([]api.Card(nil), cards...)}, nil
	}
	ids := func(record []byte) []string {
		var rec struct {
			CardIDs []string `json:"card_ids"`
		}
		if err := json.Unmarshal(record, &rec); err != nil || rec.CardIDs == nil {
			t.Fatalf("folder record %s (%v)", record, err)
		}
		return rec.CardIDs
	}
	folders, before := inboxItems(t, InboxSource(build, nil))
	if got := ids(folders["1"]); strings.Join(got, ",") != "o9,o1" {
		t.Fatalf("root card ids %v", got)
	}
	if got := ids(folders["3"]); len(got) != 0 {
		t.Fatalf("an empty folder lists %v", got)
	}

	cards = append([]api.Card{{ID: "o10", FolderID: 1}}, cards...)
	foldersAfter, after := inboxItems(t, InboxSource(build, nil))
	if got := ids(foldersAfter["1"]); strings.Join(got, ",") != "o10,o9,o1" {
		t.Fatalf("root card ids after %v", got)
	}
	for _, id := range []string{"a2", "o9", "o1"} {
		if string(before[id]) != string(after[id]) {
			t.Errorf("card %s changed: %s -> %s", id, before[id], after[id])
		}
	}
	if string(folders["2"]) != string(foldersAfter["2"]) {
		t.Errorf("an untouched folder's record changed")
	}
}
