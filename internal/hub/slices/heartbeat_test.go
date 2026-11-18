package slices

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"slices"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
	"watchtower/internal/logcanary"
)

// kitHeartbeatKeys are the Kit HeartbeatPayload coding keys as they travel
// (RelayCoder: convertToSnakeCase; hubID's key "hubId" becomes "hub_id").
var kitHeartbeatKeys = []string{
	"accounts", "app_version", "enabled_at", "flavor", "hub_id", "last_publish_at", "last_relay_at",
	"mac_name", "owner_user", "relay_backlog", "sharing", "updated_at",
}

func heartbeatFacts(clock func() time.Time, accounts func(context.Context) ([]wire.HeartbeatAccount, error)) HeartbeatFacts {
	return HeartbeatFacts{
		HubID: "0A0B0000-0000-0000-0000-000000000000", MacName: strings.Repeat("m", 70), AppVersion: "0.0.0-test",
		Flavor: wire.FlavorDefault, EnabledAt: time.Unix(1_700_000_000, 0), Accounts: accounts,
		LastPublishAt: func() (time.Time, bool) { return time.Unix(1_800_000_000, 0), true },
		LastRelayAt:   func() (time.Time, bool) { return time.Unix(1_800_000_001, 0), true },
		RelayBacklog:  func() int { return 3 },
		Clock:         clock,
	}
}

func onlyItem(t *testing.T, s Source) Item {
	t.Helper()
	items, err := s.Items(context.Background())
	if err != nil || len(items) != 1 {
		t.Fatalf("Items = %d %v", len(items), err)
	}
	return items[0]
}

func TestHeartbeatPayloadDecodesInKitShape(t *testing.T) {
	now := time.Unix(1_800_000_100, 0)
	accounts := func(context.Context) ([]wire.HeartbeatAccount, error) {
		return []wire.HeartbeatAccount{{Kind: "slack", Label: strings.Repeat("l", 90), Status: "ok"}}, nil
	}
	it := onlyItem(t, HeartbeatSource(heartbeatFacts(func() time.Time { return now }, accounts)))
	if it.ID != "" || it.Notify != "" {
		t.Fatalf("item = %q %q, want the bare heartbeat record", it.ID, it.Notify)
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(it.Payload, &m); err != nil {
		t.Fatal(err)
	}
	if got := slices.Sorted(maps.Keys(m)); !slices.Equal(got, kitHeartbeatKeys) {
		t.Fatalf("keys = %v, want %v", got, kitHeartbeatKeys)
	}
	var hb wire.Heartbeat
	if err := json.Unmarshal(it.Payload, &hb); err != nil {
		t.Fatal(err)
	}
	if hb.OwnerUser != "" || hb.Sharing != wire.SharingNone || len([]rune(hb.MacName)) != wire.MaxMacNameLength ||
		!hb.UpdatedAt.Equal(now) || hb.RelayBacklog != 3 || hb.LastRelayAt == nil {
		t.Fatalf("heartbeat = %+v", hb)
	}
	var accs []map[string]json.RawMessage
	if err := json.Unmarshal(m["accounts"], &accs); err != nil || len(accs) != 1 {
		t.Fatalf("accounts = %s %v", m["accounts"], err)
	}
	if got := slices.Sorted(maps.Keys(accs[0])); !slices.Equal(got, []string{"kind", "label", "status"}) {
		t.Fatalf("account keys = %v", got)
	}
	if len([]rune(hb.Accounts[0].Label)) != MaxAccountLabel {
		t.Fatalf("label not clipped: %d runes", len([]rune(hb.Accounts[0].Label)))
	}

	// Without accounts or counters: accounts is [] (never null), the optional stamps are absent.
	bare := onlyItem(t, HeartbeatSource(HeartbeatFacts{HubID: "h", Clock: func() time.Time { return now }}))
	if !bytes.Contains(bare.Payload, []byte(`"accounts":[]`)) || bytes.Contains(bare.Payload, []byte("last_publish_at")) {
		t.Fatalf("bare heartbeat = %s", bare.Payload)
	}
}

func TestHeartbeatRestampsOnlyOnChangeOrInterval(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	rows := []wire.HeartbeatAccount{{Kind: "slack", Label: "acme", Status: "ok"}}
	var readErr error
	src := HeartbeatSource(heartbeatFacts(func() time.Time { return now }, func(context.Context) ([]wire.HeartbeatAccount, error) {
		return slices.Clone(rows), readErr
	}))
	first := onlyItem(t, src).Payload
	now = now.Add(time.Minute)
	if got := onlyItem(t, src).Payload; !bytes.Equal(got, first) {
		t.Fatal("unchanged facts restamped the heartbeat")
	}
	sink := logcanary.Capture(t)
	readErr = errors.New("db gone")
	now = now.Add(time.Minute)
	if got := onlyItem(t, src).Payload; !bytes.Equal(got, first) {
		t.Fatal("a failed accounts read changed the heartbeat")
	}
	onlyItem(t, src)
	if n := strings.Count(sink.String(), "accounts read failed"); n != 1 {
		t.Fatalf("a failure streak logged %d lines, want 1", n)
	}
	readErr = nil
	rows[0].Status = "revoked"
	changed := onlyItem(t, src).Payload
	if bytes.Equal(changed, first) || !bytes.Contains(changed, []byte(`"revoked"`)) {
		t.Fatalf("account change not carried: %s", changed)
	}
	now = now.Add(HeartbeatInterval)
	if got := onlyItem(t, src).Payload; bytes.Equal(got, changed) {
		t.Fatal("heartbeat not restamped after the interval")
	}
}

// The heartbeat goes out under its key-free name and is not resaved while
// its payload holds.
func TestHeartbeatIsPublishedAsHeartbeat(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	p := r.publisher(HeartbeatSource(heartbeatFacts(r.clock, nil)))
	if rep := r.cycle(p); rep.Saved != 1 {
		t.Fatalf("cycle = %+v", rep)
	}
	env, ok := r.live()["heartbeat"]
	if !ok {
		t.Fatal("no heartbeat record")
	}
	if f := r.opened(env, "heartbeat"); f.Kind != "heartbeat" || f.ID != "heartbeat" {
		t.Fatalf("frame = %s %s", f.Kind, f.ID)
	}
	r.advance(time.Minute)
	if rep := r.cycle(p); rep.Saved != 0 || rep.Deleted != 0 {
		t.Fatalf("second cycle = %+v", rep)
	}
}

func TestDBAccountsReadsLabelAndStatusOnly(t *testing.T) {
	d := db.OpenTestDB(t)
	for _, q := range []string{
		`INSERT INTO slack_accounts (team_name, label, status) VALUES ( 'Acme', '', 'ok')`,
		`INSERT INTO slack_accounts (team_name, label, status) VALUES ( 'Gone', '', 'removed')`,
		`INSERT INTO google_accounts (email, label, status) VALUES ('owner@example.com', 'Work', 'error')`,
	} {
		if _, err := d.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	got, err := DBAccounts(d)(context.Background())
	want := []wire.HeartbeatAccount{{Kind: "slack", Label: "Acme", Status: "ok"}, {Kind: "google", Label: "Work", Status: "error"}}
	if err != nil || !slices.Equal(got, want) {
		t.Fatalf("accounts = %+v %v", got, err)
	}
}

// With no listed Slack account and Live on (the newest probe batch of a
// provider is ok), the phone gets one "live" Slack row; any listed Slack
// account suppresses it, and an older ok under a newer failed check is not
// Live (SLACKMODE-01, ask #1525). Screens spec §2.3.
func TestDBAccounts_LiveOnlySlackRow(t *testing.T) {
	at := time.Date(2026, 11, 18, 9, 0, 0, 0, time.UTC)
	live := wire.HeartbeatAccount{Kind: "slack", Label: "Slack", Status: "live"}
	work := wire.HeartbeatAccount{Kind: "google", Label: "Work", Status: "ok"}
	cases := []struct {
		name     string
		accounts []string
		probes   []db.SlackLiveStatus
		want     []wire.HeartbeatAccount
	}{
		{name: "nothing", want: []wire.HeartbeatAccount{}},
		{
			name:   "live only",
			probes: []db.SlackLiveStatus{{TeamID: "T1", Provider: "claude", Status: "ok", CheckedAt: at}},
			want:   []wire.HeartbeatAccount{live},
		},
		{
			name:     "live row first, before other accounts",
			accounts: []string{`INSERT INTO google_accounts (email, label, status) VALUES ('owner@example.com', 'Work', 'ok')`},
			probes:   []db.SlackLiveStatus{{Provider: "codex", Status: "ok", CheckedAt: at}},
			want:     []wire.HeartbeatAccount{live, work},
		},
		{
			name:     "a listed Slack account suppresses it",
			accounts: []string{`INSERT INTO slack_accounts (team_name, label, status, enabled) VALUES ('Acme', '', 'error', 0)`},
			probes:   []db.SlackLiveStatus{{TeamID: "T1", Provider: "claude", Status: "ok", CheckedAt: at}},
			want:     []wire.HeartbeatAccount{{Kind: "slack", Label: "Acme", Status: "error"}},
		},
		{
			name:     "a removed Slack account does not",
			accounts: []string{`INSERT INTO slack_accounts (team_name, label, status) VALUES ('Gone', '', 'removed')`},
			probes:   []db.SlackLiveStatus{{TeamID: "T1", Provider: "claude", Status: "ok", CheckedAt: at}},
			want:     []wire.HeartbeatAccount{live},
		},
		{
			name: "an older ok under a newer failed check is off",
			probes: []db.SlackLiveStatus{
				{TeamID: "T1", Provider: "claude", Status: "ok", CheckedAt: at},
				{TeamID: "", Provider: "claude", Status: "not_connected", CheckedAt: at.Add(time.Hour)},
			},
			want: []wire.HeartbeatAccount{},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := db.OpenTestDB(t)
			for _, q := range c.accounts {
				if _, err := d.Exec(q); err != nil {
					t.Fatalf("%s: %v", q, err)
				}
			}
			for _, p := range c.probes {
				if err := d.UpsertSlackLiveStatus(p); err != nil {
					t.Fatal(err)
				}
			}
			got, err := DBAccounts(d)(context.Background())
			if err != nil || !slices.Equal(got, c.want) {
				t.Fatalf("accounts = %+v %v, want %+v", got, err, c.want)
			}
		})
	}
}

// The Live row never pushes the list past MaxHeartbeatAccounts.
func TestDBAccounts_LiveOnlySlackRowKeepsTheCap(t *testing.T) {
	d := db.OpenTestDB(t)
	for i := range MaxHeartbeatAccounts {
		if _, err := d.Exec(`INSERT INTO google_accounts (email, label, status) VALUES (?, '', 'ok')`,
			fmt.Sprintf("a%d@example.com", i)); err != nil {
			t.Fatal(err)
		}
	}
	if err := d.UpsertSlackLiveStatus(db.SlackLiveStatus{Provider: "claude", Status: "ok", CheckedAt: time.Date(2026, 11, 18, 9, 0, 0, 0, time.UTC)}); err != nil {
		t.Fatal(err)
	}
	got, err := DBAccounts(d)(context.Background())
	if err != nil || len(got) != MaxHeartbeatAccounts || got[0].Status != "live" {
		t.Fatalf("accounts = %d rows, first %+v, err %v", len(got), got[0], err)
	}
}
