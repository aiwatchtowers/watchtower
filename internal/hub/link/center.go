// Package link is the hub side of linking a phone (Go hub spec §10, §12a;
// the Swift MobileLinkCenter without the CloudKit shares): the QR link code
// and its single-use nonce, the phone's hello sealed to hub_kx, the SAS v2
// four-digit code, the owner's confirmation, the device_grant keyboxes, the
// owner's grants and unlink with its epoch rotation. It is transport-neutral:
// the caller hands it hellos and publishes what Keyboxes returns.
//
// Keys are sealed only for a phone the owner confirmed under a code that was
// still valid at that moment (Review Focus 5): the decision, the link and the
// key columns are one transaction, and an unlink, a refusal or an expiry
// before it leaves no request to confirm; Keyboxes reads the linked phones
// and the epoch keys under the same lock as Unlink, so an unlinked phone
// never gets the epoch that shuts it out. Confirm takes the code the owner
// compared and refuses a request a newer or replayed hello replaced.
// Nothing here logs a name, a nonce or a key; log lines carry device ids,
// counts and classes only.
//
// For the runtime (Tasks 12, 14): HostInfo.Transports is announced as given,
// so the runtime pins it (["relay"] on a headless host, never cloudkit
// there). Each hello is tried under up to KeptCodes nonces while the
// center's lock is held, so a flood of junk hellos is bounded only by that:
// the relay's rate limits stay in front of HandleHello.
package link

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
)

// Grant is a per-phone decision the owner makes.
type Grant string

// The owner's grants. Start sessions counts only with typing allowed and the
// phone's own toggle on.
const (
	GrantTyping        Grant = "typing"
	GrantPermissions   Grant = "permissions"
	GrantStartSessions Grant = "start_sessions"
)

// Linking bounds, the Swift hub's values (spec §12a).
const (
	// KeptCodes: link_codes keeps this many, newest first.
	KeptCodes = 50
	// MaxNoncesPerCode: one code hands out at most this many confirm nonces,
	// across all phones; a further hello reads too_many_requests.
	MaxNoncesPerCode = 3
	// MaxRefusalsPerCode: refusals one code may publish on top of its nonces.
	MaxRefusalsPerCode = 10
	// MaxLinkRefusals: at most this many phones hold a refusal at once.
	MaxLinkRefusals = 50
	// MaxGrantRecords: the device_grant slice's room; linked phones are
	// never capped, the rest fill what is left.
	MaxGrantRecords = 20
	// RefusalLifetime: a refusal keybox is published this long.
	RefusalLifetime = 3600 * time.Second
	// RevokedLifetime: an unlinked phone's revoked keybox, D9.
	RevokedLifetime = 7 * 24 * time.Hour
)

// KindDeviceGrant is the slice kind every link change publishes.
const KindDeviceGrant = "device_grant"

var (
	// ErrHelloDropped: the hello is left unanswered — it opens under no kept
	// code, is malformed, or fails a check (signature, device id).
	ErrHelloDropped = errors.New("link: hello dropped")
	// ErrNoRequest: no link request waits for the device.
	ErrNoRequest = errors.New("link: no link request waits for the device")
	// ErrCodeChanged: the waiting request shows another code than the one
	// the owner confirmed (it was replaced); nothing changed, it waits.
	ErrCodeChanged = errors.New("link: the request's code changed")
	// ErrUnknownGrant: not one of the Grant values.
	ErrUnknownGrant = errors.New("link: unknown grant")
)

// HostInfo is what the hub tells phones about itself. Transports defaults to
// ["relay"] (a headless host: a phone without the relay cannot link it).
type HostInfo struct {
	Name          string
	Transports    []string
	RelayDeviceID string
	RelayAuthPub  string
}

// Config wires a Center. Clock defaults to time.Now; Publish (may be nil) is
// told the slice kinds a change touched.
type Config struct {
	Store   *state.Store
	Keys    *identity.Keyring
	Opener  *secure.Opener
	Host    HostInfo
	Clock   func() time.Time
	Publish func(kinds ...string)
}

// Center is the hub's linking state machine. Its methods are safe for
// concurrent use; the decisions run one at a time.
type Center struct {
	st      *state.Store
	keys    *identity.Keyring
	opener  *secure.Opener
	host    HostInfo
	clock   func() time.Time
	publish func(kinds ...string)
	events  chan PairEvent

	// mu serialises the deciding methods and Keyboxes, so a confirm never
	// interleaves with an unlink or a refusal of the same phone, and a
	// keybox read never straddles an unlink's rotation.
	mu sync.Mutex
	// dirty: the locked section changed the device_grant slice (guarded by mu).
	dirty bool
	// beforeKeys is a test seam: run by Keyboxes between the device read
	// and the key read.
	beforeKeys func()
}

// NewCenter builds a Center over c.
func NewCenter(c Config) *Center {
	if c.Clock == nil {
		c.Clock = time.Now
	}
	if len(c.Host.Transports) == 0 {
		c.Host.Transports = []string{wire.TransportRelay}
	}
	c.Host.Transports = append([]string(nil), c.Host.Transports...)
	return &Center{
		st: c.Store, keys: c.Keys, opener: c.Opener, host: c.Host, clock: c.Clock,
		publish: c.Publish, events: make(chan PairEvent, eventBuffer),
	}
}

// now is the clock in whole seconds, as the wire stamps it.
func (c *Center) now() time.Time { return c.clock().Truncate(time.Second).UTC() }

// changed marks the device_grant slice dirty; the deciding method publishes
// it from unlock, after c.mu is released, so a Publish callback may read
// Keyboxes or Grants synchronously. Call with c.mu held.
func (c *Center) changed() { c.dirty = true }

// unlock releases c.mu, then publishes what the locked section changed.
func (c *Center) unlock() {
	dirty := c.dirty
	c.dirty = false
	c.mu.Unlock()
	if dirty && c.publish != nil {
		c.publish(KindDeviceGrant)
	}
}

// Unlink removes a linked phone and rotates the epoch in the same
// transaction (identity.RotateWith, reason unlink): its row, refusal, pending
// request, rollback marks and held actions go, and it gets a revoked row so
// its keybox reads revoked (no keys) for RevokedLifetime. A phone that only
// waits for the owner is refused not_confirmed instead (it never had keys,
// nothing rotates). state.ErrNoDevice when neither.
func (c *Center) Unlink(device string) error {
	c.mu.Lock()
	defer c.unlock()
	removed := false
	err := c.keys.RotateWith(identity.ReasonUnlink, func(tx *sql.Tx) error {
		ok, err := removeDevice(tx, device, c.now())
		if err != nil {
			return err
		}
		if !ok {
			return identity.ErrSkipRotation
		}
		removed = true
		return nil
	})
	if err != nil {
		return fmt.Errorf("unlinking a phone: %w", err)
	}
	if removed {
		log.Printf("hub link: phone %s unlinked, epoch rotated", strings.ToUpper(device))
		c.changed()
		return nil
	}
	var refused *pendingDevice
	err = c.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		p, ok, err := pendingTx(tx, device)
		if err != nil || !ok {
			return err
		}
		refused = &p
		return refusePending(tx, p, wire.RefusedNotConfirmed, c.now())
	})
	if err != nil {
		return fmt.Errorf("unlinking a waiting phone: %w", err)
	}
	if refused == nil {
		return state.ErrNoDevice
	}
	c.refusedEvent(*refused, wire.RefusedNotConfirmed)
	return nil
}

// grantColumns maps a Grant to its devices column.
var grantColumns = map[Grant]string{
	GrantTyping:        "typing_allowed",
	GrantPermissions:   "permissions_allowed",
	GrantStartSessions: "start_sessions_granted",
}

// Allow sets or revokes one of a linked phone's grants and stamps decided_at.
// ErrUnknownGrant for another value, state.ErrNoDevice when not linked.
func (c *Center) Allow(device string, g Grant, on bool) error {
	col, ok := grantColumns[g]
	if !ok {
		return fmt.Errorf("%w: %q", ErrUnknownGrant, g)
	}
	c.mu.Lock()
	defer c.unlock()
	err := c.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		res, err := tx.Exec(`UPDATE devices SET `+col+` = ?, decided_at = ? WHERE device_id = ? COLLATE NOCASE`,
			on, secs(c.now()), device)
		if err != nil {
			return err
		}
		if n, err := res.RowsAffected(); err != nil {
			return err
		} else if n == 0 {
			return state.ErrNoDevice
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("setting a grant: %w", err)
	}
	c.changed()
	return nil
}

// Sweep is the per-cycle housekeeping: every request still waiting under a
// code that expired is refused expired_code (the Swift expiry close), and
// refusals and revoked rows past their lifetime are forgotten.
func (c *Center) Sweep() error {
	c.mu.Lock()
	defer c.unlock()
	now := c.now()
	var refused []pendingDevice
	err := c.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		all, err := pendingDevicesTx(tx)
		if err != nil {
			return err
		}
		for _, p := range all {
			code, ok, err := linkCodeTx(tx, p.linkNonce)
			if err != nil {
				return err
			}
			if ok && !code.exp.Before(now) {
				continue
			}
			if err := refusePending(tx, p, wire.RefusedExpiredCode, now); err != nil {
				return err
			}
			refused = append(refused, p)
		}
		if _, err := tx.Exec(`DELETE FROM link_refusals WHERE at < ?`, secs(now.Add(-RefusalLifetime))); err != nil {
			return err
		}
		_, err = tx.Exec(`DELETE FROM revoked_devices WHERE removed_at <= ?`, secs(now.Add(-RevokedLifetime)))
		return err
	})
	if err != nil {
		return fmt.Errorf("sweeping link state: %w", err)
	}
	for _, p := range refused {
		c.refusedEvent(p, wire.RefusedExpiredCode)
	}
	if len(refused) > 0 {
		log.Printf("hub link: %d waiting requests refused at their code's expiry", len(refused))
	}
	return nil
}

func (c *Center) refusedEvent(p pendingDevice, reason string) {
	c.emit(PairEvent{Kind: EventRefused, DeviceID: p.deviceID, Name: p.name, Reason: reason})
	c.changed()
}

// removeDevice deletes a linked phone with everything keyed on it and writes
// its revoked row (when it has an agreement key), in tx; false when no phone
// is linked under that id (any case).
func removeDevice(tx *sql.Tx, device string, at time.Time) (bool, error) {
	var (
		id, name, scope string
		agreement       []byte
	)
	err := tx.QueryRow(`SELECT device_id, name, scope, agreement_key FROM devices WHERE device_id = ? COLLATE NOCASE`, device).
		Scan(&id, &name, &scope, &agreement)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	for _, q := range []string{
		`DELETE FROM devices WHERE device_id = ? COLLATE NOCASE`,
		`DELETE FROM link_refusals WHERE device_id = ? COLLATE NOCASE`,
		`DELETE FROM pending_devices WHERE device_id = ? COLLATE NOCASE`,
		`DELETE FROM revoked_devices WHERE device_id = ? COLLATE NOCASE`,
		`DELETE FROM relay_seen WHERE sender_id = ? COLLATE NOCASE`,
		`DELETE FROM held_actions WHERE device_id = ? COLLATE NOCASE`,
	} {
		if _, err := tx.Exec(q, device); err != nil {
			return false, err
		}
	}
	if agreement != nil {
		if _, err := tx.Exec(`INSERT INTO revoked_devices (device_id, name, scope, agreement_key, removed_at) VALUES (?, ?, ?, ?, ?)`,
			strings.ToUpper(id), name, scope, agreement, secs(at)); err != nil {
			return false, err
		}
	}
	return true, nil
}

// Times are REAL seconds since 1970, as the Swift hub stores them.

func secs(t time.Time) float64 { return float64(t.UnixNano()) / 1e9 }

func fromReal(f float64) time.Time {
	return time.Unix(0, int64(f*1e9)).UTC().Round(time.Microsecond)
}
