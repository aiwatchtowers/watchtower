package inboxfeed

import (
	"bytes"
	"context"
	"log"
	"os"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/tools"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
)

// ownerSeed holds a row for every owner gesture: a pending proposal #1, a
// card with a Reply and a target button, a message to reply to, a custom
// track bound to a watch recipe with an event, and an open card for Done.
var ownerSeed = []string{
	`INSERT INTO agent_actions (id, tool, args_json, reason, status, created_at)
		VALUES (1, 'fake', '` + pendingArgs + `', 'r', 'pending', '2026-11-16T09:00:00Z')`,
	`INSERT INTO automations (id, slug, scope, path, name, enabled, origin) VALUES (1, 'd', 'personal', '/r/d.md', 'D', 1, 'owner')`,
	`INSERT INTO automations (id, slug, scope, path, name, enabled, origin) VALUES (4, 'w', 'personal', '/r/w.md', 'W', 0, 'owner')`,
	`INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES (1, 1, 'manual', 'succeeded')`,
	`INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, content_hash, actions_json)
		VALUES (1, 1, 1, 'inbox', 'C', 'b', 'h1', '[{"label":"R","kind":"reply","reply":"r"},{"label":"T","kind":"target","target":{"title":"Do it"}}]')`,
	`INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type, permalink, created_at)
		VALUES (1, 'C1', '1.0', 'U1', 'mention', 'https://acme.slack.com/archives/C1/p1', '2026-11-16T07:00:00Z')`,
	`INSERT INTO targets (id, text, level, status, period_start, period_end) VALUES (3, 'Ship', 'day', 'todo', '2026-11-16', '2026-11-16')`,
	`INSERT INTO tracks (id, text, origin, linked_target_id, automation_id, enabled, dismissed_at)
		VALUES (1, 'Billing', 'custom', 3, 4, 0, '2026-11-16T08:00:00Z')`,
	`INSERT INTO track_events (id, track_id, summary, created_at, proposed_action, action_status)
		VALUES (2, 1, 'Done', '2026-11-16T09:00:00Z', '{"type":"update_status","status":"done"}', 'pending')`,
}

// TestInboxAct_OwnerGesturesNeedTheSignedDesktop (AGENT-07 over the
// socket): every verb whose CLI twin is an owner gesture — approve, retry
// (apply), dismiss of a session call, a press (`automations reply`,
// `actions propose`), a row's Reply, make_task (`actions propose
// --approve`), Restore of a recipe-bound track (`automations enable`) — is
// refused not_permitted from a socket peer that is not the signed Desktop,
// and nothing is written; an open verb (Done) is not.
func TestInboxAct_OwnerGesturesNeedTheSignedDesktop(t *testing.T) {
	index := 0
	owner := []struct {
		name   string
		target string
		verb   api.ActVerb
		p      api.ActParams
	}{
		{"approve", "a1", api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalApprove, ArgsSHA256: tools.ArgsSHA256(pendingArgs)}},
		{"retry", "a1", api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalRetry}},
		{"dismiss", "a1", api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalDismiss}},
		{"press_reply", "o1", api.ActPress, api.ActParams{ContentHash: "h1", Index: &index}},
		{"press_target", "o1", api.ActPress, api.ActParams{ContentHash: "h1", Index: new(1)}},
		{"reply_propose", "messages", api.ActReplyPropose, api.ActParams{RefKind: api.RefInboxItem, RefID: 1, Text: "On it"}},
		{"make_task", "tracks", api.ActRef, api.ActParams{RefKind: api.RefTrack, RefID: 1, RefVerb: api.RefMakeTask, EventID: 2}},
		{"restore_bound_track", "tracks", api.ActRef, api.ActParams{RefKind: api.RefTrack, RefID: 1, RefVerb: api.RefRestore}},
	}
	for _, o := range owner {
		t.Run(o.name, func(t *testing.T) {
			for _, origin := range []tower.Origin{unsigned, {Transport: "socket"}} {
				d := seeded(t, ownerSeed)
				deps := fixtureDeps(t, d)
				if err := deps.Registry.Register(fakeTool(t, "fake", nil, nil)); err != nil {
					t.Fatal(err)
				}
				before := ownerRows(t, d)
				resp := callAct(t, actTower(d, actNow, deps), actParams(t, o.target, o.verb, o.p), origin)
				if resp.Status != api.StatusRefused || resp.Refusal.Code != api.CodeNotPermitted ||
					!strings.HasSuffix(resp.Refusal.Sentence, "the owner decides in Watchtower Desktop.") {
					t.Fatalf("got %s %+v, want not_permitted", resp.Status, resp.Refusal)
				}
				if after := ownerRows(t, d); after != before {
					t.Errorf("a refused gesture wrote:\n%s\nwant\n%s", after, before)
				}
			}
		})
	}
	t.Run("done_is_open", func(t *testing.T) {
		d := seeded(t, ownerSeed)
		resp := callAct(t, actTower(d, actNow, fixtureDeps(t, d)), actParams(t, "o1", api.ActDone, api.ActParams{ContentHash: "h1"}), unsigned)
		if res := actResult(t, resp); res.Already {
			t.Errorf("Done from an unsigned peer %+v, want written", res)
		}
	})
}

func ownerRows(t *testing.T, d *db.DB) string {
	t.Helper()
	var b strings.Builder
	for _, q := range []string{
		`SELECT COUNT(*) || ':' || GROUP_CONCAT(status) FROM agent_actions`,
		`SELECT COUNT(*) FROM automation_runs`,
		`SELECT COALESCE(pressed_at, '') FROM automation_outputs`,
		`SELECT enabled FROM automations WHERE id = 4`,
		`SELECT dismissed_at || ':' || enabled FROM tracks`,
		`SELECT status FROM targets`,
	} {
		var s string
		if err := d.QueryRow(q).Scan(&s); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
		b.WriteString(s + "\n")
	}
	return b.String()
}

// TestInboxAct_HubDoesNotTurnRecipesOnOrOff (ask #1349): from the phone,
// Stop and Restore of a track bound to a watch recipe are not permitted,
// and an approved create_track applies without starting its watch, its
// answer noting that the watch starts from the Mac.
func TestInboxAct_HubDoesNotTurnRecipesOnOrOff(t *testing.T) {
	for _, verb := range []api.RefVerb{api.RefStop, api.RefRestore} {
		d := seeded(t, ownerSeed)
		before := ownerRows(t, d)
		resp := callAct(t, actTower(d, actNow, fixtureDeps(t, d)),
			actParams(t, "tracks", api.ActRef, api.ActParams{RefKind: api.RefTrack, RefID: 1, RefVerb: verb}), hub)
		if resp.Status != api.StatusRefused || resp.Refusal.Code != api.CodeNotPermitted ||
			!strings.HasSuffix(resp.Refusal.Sentence, "this is done on the Mac.") {
			t.Errorf("%s from the hub: %s %+v, want not_permitted", verb, resp.Status, resp.Refusal)
		}
		if after := ownerRows(t, d); after != before {
			t.Errorf("%s from the hub wrote", verb)
		}
	}

	d := seeded(t, []string{`INSERT INTO agent_actions (id, tool, args_json, reason, status, created_at)
		VALUES (1, 'create_track', '` + pendingArgs + `', 'r', 'pending', '2026-11-16T09:00:00Z')`})
	reg := tools.New(d)
	tool := fakeTool(t, "create_track", nil, nil)
	tool.Execute = func(context.Context, *db.DB, tools.Call) (any, error) { return map[string]any{"track_id": 7}, nil }
	if err := reg.Register(tool); err != nil {
		t.Fatal(err)
	}
	started := 0
	var later []func()
	tw := actTower(d, actNow, ActDeps{Registry: reg, Background: func(fn func()) { later = append(later, fn) },
		StartWatch: func(context.Context, int64) error { started++; return nil }})
	res := actResult(t, callAct(t, tw, actParams(t, "a1", api.ActApproval,
		api.ActParams{ApprovalVerb: api.ApprovalApprove, ArgsSHA256: tools.ArgsSHA256(pendingArgs)}), hub))
	if res.Note != "Start watching it from your Mac." {
		t.Errorf("hub approve %+v, want the watch note", res)
	}
	for _, fn := range later {
		fn()
	}
	if s := actionStatusOf(t, d, 1); s != "applied" || started != 0 {
		t.Errorf("row %s, %d watch starts; want applied and no start from the hub", s, started)
	}
}

// TestInboxAct_LateApproveOutcomeIsLoggedAndOnTheRow: an approve whose tool
// fails after the 120 s answer logs the outcome (status, error) by action
// id, and the row carries failed with its error to the next feed.
func TestInboxAct_LateApproveOutcomeIsLoggedAndOnTheRow(t *testing.T) {
	var buf bytes.Buffer
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	synctest.Test(t, func(t *testing.T) {
		d, _, reg := approvalRig(t, nil)
		tool, _ := reg.Get("fake")
		tool.Execute = func(context.Context, *db.DB, tools.Call) (any, error) {
			time.Sleep(10 * time.Minute)
			return nil, errBoom
		}
		res := actResult(t, callAct(t, actTower(d, actNow, ActDeps{Registry: reg}),
			approveParams(t, tools.ArgsSHA256(pendingArgs)), socket))
		if res.Status != "applying" {
			t.Fatalf("answer %+v, want applying", res)
		}
		time.Sleep(10 * time.Minute)
		synctest.Wait()
		row, err := d.GetAgentAction(1)
		if err != nil || row.Status != "failed" || row.Error != errBoom.Error() {
			t.Errorf("row %+v %v, want failed with the tool's error", row, err)
		}
		feed, err := Build(context.Background(), d, Options{Now: actNow})
		if err != nil {
			t.Fatal(err)
		}
		found := false
		for _, c := range feed.Cards {
			if c.ID == "a1" && c.Approval != nil && c.Approval.Status == "failed" && c.Approval.Error == errBoom.Error() {
				found = true
			}
		}
		if !found {
			t.Error("the failed approve is not on the next feed")
		}
	})
	if !strings.Contains(buf.String(), "inbox.act: action 1 finished after the 120 s wait: failed: "+errBoom.Error()) {
		t.Errorf("log %q, want the late outcome", buf.String())
	}
}

var errBoom = errorString("the channel is archived")

type errorString string

func (e errorString) Error() string { return string(e) }
