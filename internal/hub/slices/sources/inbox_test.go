package sources

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"slices"
	"strconv"
	"testing"
	"time"

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
// folder or card; a legacy card carries its projected document and only its
// section's kind.
func TestInboxSource_RecordsMatchTheGoGolden(t *testing.T) {
	ran := 0
	for _, c := range inboxCases(t) {
		if c.Opts.Folder != nil || c.Opts.Limit != 0 {
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
			folders, cards := inboxItems(t, InboxSource(build, func() time.Time { return now }, time.UTC))

			if len(folders) != len(c.Expect.Folders) || len(cards) != len(c.Expect.Cards) {
				t.Fatalf("%d folders, %d cards; want %d, %d", len(folders), len(cards), len(c.Expect.Folders), len(c.Expect.Cards))
			}
			for _, f := range c.Expect.Folders {
				want := marshalWire(t, inboxFolderRecord{Folder: f})
				if got := folders[strconv.FormatInt(f.ID, 10)]; string(got) != string(want) {
					t.Errorf("folder %d:\n got %s\nwant %s", f.ID, got, want)
				}
			}
			for _, card := range c.Expect.Cards {
				if card.Legacy != nil {
					doc, err := inboxlegacy.Project(*card.Legacy, time.UTC)
					if err != nil {
						t.Fatal(err)
					}
					card.Blocks = doc
					card.Legacy = &api.LegacySection{Kind: card.Legacy.Kind, Items: []api.LegacyItem{}, Attention: []api.LegacyAttention{}}
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
	folders, _ := inboxItems(t, InboxSource(build, func() time.Time { return now }, time.UTC))
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
	srcs := InboxSource(build, nil, time.UTC)
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
	folders, cards := inboxItems(t, InboxSource(build, func() time.Time { return now }, time.UTC))
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
