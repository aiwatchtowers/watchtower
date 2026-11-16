package hub

import (
	"context"
	"slices"
	"testing"

	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/transport"
	"watchtower/internal/inboxfeed"
	"watchtower/internal/policy"
	"watchtower/internal/tower"
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
// hub publishes the Inbox from inbox.feed, its handlers reach inbox.act and
// the heartbeat says "on"; under workbench_only it publishes no Inbox kind
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
