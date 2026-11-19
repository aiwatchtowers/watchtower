package hub

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"testing"

	"watchtower/internal/db"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/hub/transport"
	"watchtower/internal/inboxfeed"
	"watchtower/internal/policy"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
)

// inboxRig is a chat rig whose hub has the daemon's tower with the Inbox
// commands.
func inboxRig(t *testing.T, mode string) *chatRig {
	t.Helper()
	return newChatRigWith(t, mode, transport.KindRelay, func(o *Options) {
		var r tower.Registry
		inboxfeed.Register(&r, nil)
		inboxfeed.RegisterAct(&r, inboxfeed.ActDeps{})
		o.Tower = tower.New(o.DB, tower.Options{Registry: &r})
	})
}

func sourceKinds(r *chatRig) []hubslices.Kind {
	var out []hubslices.Kind
	for _, s := range r.w.set.Sources {
		out = append(out, s.Kind())
	}
	return out
}

// TestInboxWiring_TheTowerFeedsThePhoneInbox: with the daemon's tower the
// hub publishes the Inbox from inbox.feed and the heartbeat says "on"; under workbench_only it publishes no Inbox kind
// and says policy_off; without a tower it says nothing.
func TestInboxWiring_TheTowerFeedsThePhoneInbox(t *testing.T) {
	r := inboxRig(t, policy.MobileAllowed)
	kinds := sourceKinds(r)
	if !slices.Contains(kinds, hubslices.KindInboxFolder) || !slices.Contains(kinds, hubslices.KindInboxCard) {
		t.Fatalf("sources %v", kinds)
	}
	for _, s := range r.w.set.Sources {
		if s.Kind() != hubslices.KindInboxFolder {
			continue
		}
		items, err := s.Items(context.Background())
		if err != nil || len(items) == 0 {
			t.Fatalf("inbox_folder through the tower: %d items, %v", len(items), err)
		}
	}
	if on := r.h.inboxAvailable(); on == nil || !on() {
		t.Fatal("the heartbeat does not say the Inbox is on")
	}
	if f := r.h.heartbeat(r.st, "Mac"); f.Inbox == nil {
		t.Fatal("the heartbeat facts carry no Inbox")
	}

	wo := inboxRig(t, policy.MobileWorkbenchOnly)
	if kinds := sourceKinds(wo); slices.Contains(kinds, hubslices.KindInboxFolder) || slices.Contains(kinds, hubslices.KindInboxCard) {
		t.Fatalf("workbench_only sources %v", kinds)
	}
	if on := wo.h.inboxAvailable(); on == nil || on() {
		t.Fatal("workbench_only does not say policy_off")
	}

	if none := newChatRig(t, policy.MobileAllowed, transport.KindRelay); none.h.inboxAvailable() != nil ||
		slices.Contains(sourceKinds(none), hubslices.KindInboxCard) {
		t.Fatal("a hub without a tower offers the Inbox")
	}
}

// TestInboxWiring_PhoneFeedOmitsTheJournalBeforeTheLimit: the phone's feed
// goes through towerInboxFeed and the tower's inbox.feed with OmitMacOnly,
// so at the cap a fresh Watchman journal card takes no slot and adds
// nothing to `more`; the Mac's request (no OmitMacOnly) still gets it.
func TestInboxWiring_PhoneFeedOmitsTheJournalBeforeTheLimit(t *testing.T) {
	ctx := context.Background()
	seed := []string{
		"INSERT INTO automations (id, slug, scope, path, name) VALUES (1, 'a', 'personal', '/recipes/a.md', 'A')",
		"INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES (1, 1, 'manual', 'succeeded')",
		"INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, created_at) VALUES (1, 1, 1, 'inbox', 'One', 'B', '2026-11-16T06:00:00Z')",
		"INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, created_at) VALUES (2, 1, 1, 'inbox', 'Two', 'B', '2026-11-16T07:00:00Z')",
		"INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, created_at) VALUES (3, 1, 1, 'inbox', 'Three', 'B', '2026-11-16T08:00:00Z')",
	}
	journal := []string{
		"INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme')",
		"INSERT INTO watchman_workbenches (workbench_id, enabled_at) VALUES (1, '2026-11-10T09:00:00Z')",
		"INSERT INTO watchman_items (id, workbench_id, kind, ref_kind, ref_id, state, outcome, created_at) " +
			"VALUES (1, 1, 'ask', 'ask', 1, 'done', 'parked', '2026-11-16T11:00:00Z')",
	}
	feed := func(stmts []string) sources.InboxFeed {
		d := db.OpenTestDB(t)
		for _, s := range stmts {
			if _, err := d.Exec(s); err != nil {
				t.Fatalf("%s: %v", s, err)
			}
		}
		var r tower.Registry
		inboxfeed.Register(&r, nil)
		return towerInboxFeed(tower.New(d, tower.Options{Registry: &r}))
	}
	ids := func(f api.Feed) string {
		var out []string
		for _, c := range f.Cards {
			out = append(out, c.ID)
		}
		return strings.Join(out, ",")
	}
	phone := inboxfeed.Options{Limit: 2, Clip: true, OmitMacOnly: true}
	want, err := feed(seed)(ctx, phone)
	if err != nil {
		t.Fatal(err)
	}
	withJournal := feed(append(append([]string{}, seed...), journal...))
	got, err := withJournal(ctx, phone)
	if err != nil {
		t.Fatal(err)
	}
	if ids(got) != ids(want) || len(got.Cards) != 2 || strings.Contains(ids(got), inboxfeed.WatchmanCardID) {
		t.Errorf("phone cards %q, want %q", ids(got), ids(want))
	}
	if fmt.Sprint(got.More) != fmt.Sprint(want.More) || len(got.More) == 0 {
		t.Errorf("phone more %+v, want %+v", got.More, want.More)
	}
	mac, err := withJournal(ctx, inboxfeed.Options{Limit: 2, Clip: true})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(ids(mac), inboxfeed.WatchmanCardID) {
		t.Errorf("without OmitMacOnly the feed has no journal card: %q", ids(mac))
	}
}
