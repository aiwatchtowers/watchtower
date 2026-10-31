package slices

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"slices"
	"sync"
	"time"

	"watchtower/internal/hub/wire"
)

// Heartbeat limits and cadence (the Kit's HeartbeatPayload, the Swift
// MobileHubService).
const (
	// MaxHeartbeatAccounts is HeartbeatPayload.maxAccounts.
	MaxHeartbeatAccounts = 20
	// MaxAccountLabel is HeartbeatAccount.maxLabelLength, in runes.
	MaxAccountLabel = 80
	// HeartbeatInterval: the heartbeat is restamped at least this often
	// (the phone calls a hub stale after 35 min); a change in its accounts
	// restamps it at once.
	HeartbeatInterval = 15 * time.Minute
)

// HeartbeatFacts is what the heartbeat carries besides its stamp. Accounts
// reads the account rows (DBAccounts); LastPublishAt, LastRelayAt and
// RelayBacklog may be nil (absent, absent, 0). Recordings reads the recording
// switch (protocol §9); nil carries no capabilities. Clock defaults to
// time.Now.
type HeartbeatFacts struct {
	HubID         string
	MacName       string
	AppVersion    string
	Flavor        string
	EnabledAt     time.Time
	Accounts      func(ctx context.Context) ([]wire.HeartbeatAccount, error)
	LastPublishAt func() (time.Time, bool)
	LastRelayAt   func() (time.Time, bool)
	RelayBacklog  func() int
	Recordings    func() bool
	Clock         func() time.Time
}

// HeartbeatSource is the hub's liveness record, record "heartbeat". It is
// restamped (updated_at and the counters read anew) when its accounts or the
// recording switch change and at least every HeartbeatInterval; between
// those it returns the same payload, so the 60 s full diff saves nothing. A failed accounts read keeps
// the accounts last carried (none before the first). owner_user is "" and
// sharing "none": a relay-only hub has no iCloud user and no share (gap 6).
//
// Phase-1 isolation: the accounts come from the database the hub is given;
// the runtime (Task 14) starts the hub only in a hubtest-* test workspace,
// so in phase 1 that is always the test workspace's database.
func HeartbeatSource(f HeartbeatFacts) Source {
	if f.Clock == nil {
		f.Clock = time.Now
	}
	return &heartbeatSource{f: f}
}

type heartbeatSource struct {
	f HeartbeatFacts

	mu       sync.Mutex
	accounts []wire.HeartbeatAccount    // what the current payload carries
	caps     wire.HeartbeatCapabilities // what the current payload carries (zero = none)
	payload  []byte
	stamped  time.Time
	failing  bool // the accounts read failed last time (logged once per streak)
}

func (*heartbeatSource) Kind() Kind { return KindHeartbeat }

func (h *heartbeatSource) Items(ctx context.Context) ([]Item, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.f.Clock()
	accounts, err := h.readAccounts(ctx)
	changed := false
	if err != nil {
		if !h.failing {
			log.Printf("hub slices: heartbeat accounts read failed (%s): last accounts kept", errClass(err))
		}
		h.failing = true
		accounts = h.accounts
	} else {
		h.failing = false
		changed = !slices.Equal(accounts, h.accounts)
	}
	var caps wire.HeartbeatCapabilities
	if h.f.Recordings != nil {
		caps = *wire.RecordingsCapability(h.f.Recordings())
	}
	changed = changed || caps != h.caps
	if h.payload == nil || changed || now.Sub(h.stamped) >= HeartbeatInterval {
		payload, err := wire.Marshal(h.build(now, accounts, caps))
		if err != nil {
			return nil, fmt.Errorf("slices: encoding the heartbeat: %w", err)
		}
		h.payload, h.accounts, h.caps, h.stamped = payload, accounts, caps, now
	}
	return []Item{{Payload: h.payload}}, nil
}

func (h *heartbeatSource) readAccounts(ctx context.Context) ([]wire.HeartbeatAccount, error) {
	if h.f.Accounts == nil {
		return []wire.HeartbeatAccount{}, nil
	}
	got, err := h.f.Accounts(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]wire.HeartbeatAccount, 0, min(len(got), MaxHeartbeatAccounts))
	for _, a := range got[:min(len(got), MaxHeartbeatAccounts)] {
		a.Label = clipRunes(a.Label, MaxAccountLabel)
		out = append(out, a)
	}
	return out, nil
}

func (h *heartbeatSource) build(now time.Time, accounts []wire.HeartbeatAccount, caps wire.HeartbeatCapabilities) wire.Heartbeat {
	if accounts == nil {
		accounts = []wire.HeartbeatAccount{} // the Kit's accounts is not optional: [] never null
	}
	hb := wire.Heartbeat{
		UpdatedAt: wire.Time{Time: now}, AppVersion: h.f.AppVersion, HubID: h.f.HubID,
		MacName: wire.ClipMacName(h.f.MacName), Flavor: h.f.Flavor, Accounts: accounts,
		EnabledAt: wire.Time{Time: h.f.EnabledAt}, OwnerUser: "", Sharing: wire.SharingNone,
	}
	if caps != (wire.HeartbeatCapabilities{}) {
		hb.Capabilities = &caps
	}
	if h.f.LastPublishAt != nil {
		if at, ok := h.f.LastPublishAt(); ok {
			hb.LastPublishAt = &wire.Time{Time: at}
		}
	}
	if h.f.LastRelayAt != nil {
		if at, ok := h.f.LastRelayAt(); ok {
			hb.LastRelayAt = &wire.Time{Time: at}
		}
	}
	if h.f.RelayBacklog != nil {
		hb.RelayBacklog = h.f.RelayBacklog()
	}
	return hb
}

// accountsSQL is the Swift HubAccountRows query: kind, label and status of
// each Slack, Google and Jira account, at most MaxHeartbeatAccounts. Only
// those columns are read, so no token can reach the payload.
const accountsSQL = `SELECT kind, label, status FROM (
	SELECT 0 AS ord, id, 'slack' AS kind, COALESCE(NULLIF(label, ''), team_name) AS label, status
	FROM slack_accounts WHERE status != 'removed'
	UNION ALL
	SELECT 1, id, 'google', COALESCE(NULLIF(label, ''), email), status FROM google_accounts
	UNION ALL
	SELECT 2, id, 'jira', COALESCE(NULLIF(label, ''), site_name), status
	FROM jira_accounts WHERE status != 'removed'
) ORDER BY ord, id LIMIT ?`

// DBAccounts reads the heartbeat's account rows from db, the daemon's
// watchtower.db. Phase 1: the runtime refuses to start the hub in any
// workspace but a hubtest-* test workspace (Task 14), so db is always that
// workspace's database, never the owner's live one.
func DBAccounts(db *sql.DB) func(ctx context.Context) ([]wire.HeartbeatAccount, error) {
	return func(ctx context.Context) ([]wire.HeartbeatAccount, error) {
		rows, err := db.QueryContext(ctx, accountsSQL, MaxHeartbeatAccounts)
		if err != nil {
			return nil, fmt.Errorf("slices: reading the accounts: %w", err)
		}
		defer rows.Close()
		out := []wire.HeartbeatAccount{}
		for rows.Next() {
			var a wire.HeartbeatAccount
			if err := rows.Scan(&a.Kind, &a.Label, &a.Status); err != nil {
				return nil, fmt.Errorf("slices: reading the accounts: %w", err)
			}
			out = append(out, a)
		}
		if err := rows.Err(); err != nil {
			return nil, fmt.Errorf("slices: reading the accounts: %w", err)
		}
		return out, nil
	}
}

func clipRunes(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
}
