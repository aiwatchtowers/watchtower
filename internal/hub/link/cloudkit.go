package link

// Linking over CloudKit (Go hub phase 3 Task 12; the share half of the Swift
// MobileLinkCenter): the account check, the two zone shares and their public
// link window, the participant sweep, and hellos read from the shared
// RelayZone with the participant check. The share calls go through
// transport.Shares (the CloudKit bridge); share URLs are opaque and never
// parsed or logged, and log lines carry device ids, counts and error
// classes only — never a code, a URL, a nonce, a phone name or a user
// record name (FILES-01).
//
// The Swift center ran its waits (the expiry timer, the answer grace, the
// retries of a failed close) as tasks. Here they are deadlines kept in
// memory and acted on by SweepShares, which the runtime calls on every relay
// pass; the "sweep needed" mark itself is the Swift hub_meta key
// (MetaShareSweepPending), so a crash with the link open is still closed by
// the next run's CloseLink(CloseRestart).

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"slices"
	"strings"
	"sync"
	"time"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// CloudKitContainer is the CloudKit container a CloudKit code names: the
// Kit's WatchtowerCloud.containerID (a phone refuses a code of another
// container, wrong_container).
const CloudKitContainer = "iCloud.com.aiwatchtowers.watchtower"

// MetaShareSweepPending is the Swift hub's hub_meta key: "1" while the
// shares need a close-and-sweep (from just before the public link opens, or
// after an unlink whose participant was not removed) until a sweep
// succeeds; "0" after it.
const MetaShareSweepPending = "share_sweep_pending"

// ShareTimeout bounds every share call (the Swift MobileHubService
// defaultCloudTimeout): offline CloudKit waits for connectivity.
const ShareTimeout = 30 * time.Second

// Sweep is the participant sweep's timing.
type Sweep struct {
	// AnswerGrace is how long an answering close (CloseUsed, CloseExpired,
	// CloseSheetClosed) keeps the unbound participants: a phone that
	// accepted the public link but had not written its hello yet still
	// reads its refusal in the data zone. The public link closes at once.
	AnswerGrace time.Duration
}

// DefaultSweep is today's MobileLinkCenter.answerGrace, 120 s.
var DefaultSweep = Sweep{AnswerGrace: 120 * time.Second}

// Retry waits, the Swift values: a failed sweep after each of
// sweepRetryDelays, then left to the next close; a failed public-link close
// of an answering close after each of linkCloseRetryDelays (the grace's
// sweep closes it too).
var (
	sweepRetryDelays     = []time.Duration{60 * time.Second, 300 * time.Second, 900 * time.Second, 3600 * time.Second}
	linkCloseRetryDelays = []time.Duration{15 * time.Second, 60 * time.Second}
)

// CloseReason is why the link closes (the Swift CloseReason raw values).
type CloseReason string

// The close reasons.
const (
	CloseUsed        CloseReason = "used"
	CloseExpired     CloseReason = "expired"
	CloseSheetClosed CloseReason = "sheet_closed"
	// CloseRestart: a link left open by an earlier run (a crash with the QR
	// shown); the runtime closes it once at start.
	CloseRestart CloseReason = "restart"
	// CloseIssueFailed: the code could not be stored after its link opened.
	CloseIssueFailed CloseReason = "issue_failed"
	// CloseAccountChanged: the Mac's iCloud account changed; the QR names
	// the old user.
	CloseAccountChanged CloseReason = "account_changed"
)

// answersLateHellos: a phone that joined the shares may still send its
// hello after this close, so its participant stays for the answer grace.
func (r CloseReason) answersLateHellos() bool {
	return r == CloseUsed || r == CloseExpired || r == CloseSheetClosed
}

// refusal is what a request still waiting at this close reads.
func (r CloseReason) refusal() string {
	switch r {
	case CloseUsed:
		return wire.RefusedUsedCode
	case CloseExpired:
		return wire.RefusedExpiredCode
	case CloseSheetClosed, CloseRestart, CloseIssueFailed, CloseAccountChanged:
	}
	return wire.RefusedNotConfirmed
}

// Sharing states the heartbeat's sharing field reads.
const (
	SharingAvailable   = "available"
	SharingUnavailable = "unavailable"
)

var (
	// ErrOwnerUnknown: the Mac's iCloud user could not be read; no code.
	ErrOwnerUnknown = errors.New("link: the Mac's iCloud user is unknown")
	// ErrNoRelayID: the center has no relay device id to name the zones.
	ErrNoRelayID = errors.New("link: no relay device id names the hub's zones")
)

// AccountError refuses a CloudKit code: the Mac's iCloud account is not
// available (Account is its state, the error class).
type AccountError struct{ Account transport.Account }

func (e *AccountError) Error() string { return "link: the iCloud account is " + string(e.Account) }

// ckState is the share calls' state, guarded by mu, which also runs the
// CloudKit linking calls one at a time (they do I/O; never held by a holder
// of Center.mu).
type ckState struct {
	mu sync.Mutex
	// open is the code on screen, nil once it was used, expired or closed.
	open *openCode
	// graceEnd: an answering close's grace runs until then.
	graceEnd time.Time
	// sweepAt: a deferred sweep (the grace's end, or a retry) is due then;
	// zero when none. sweepTries counts the retries spent.
	sweepAt    time.Time
	sweepTries int
	// linkCloseAt: a failed public-link close is retried then; zero when
	// none. linkCloseTries counts the retries spent.
	linkCloseAt    time.Time
	linkCloseTries int
	// sharing: what the last issue left (SharingAvailable/Unavailable), ""
	// before any.
	sharing string
}

type openCode struct {
	nonce string
	exp   time.Time
}

// retiredCode is the code an answering close retired and the refusal a
// hello under it reads; empty when none.
type retiredCode struct{ nonce, reason string }

// IssueCloudKit makes a CloudKit QR code (the Swift issueCode): it refuses
// without an available iCloud account (*AccountError, no share call) or the
// Mac's user (ErrOwnerUnknown); creates the zone shares if missing, marks
// the sweep pending and opens their public link — a failure there leaves the
// share URLs out (only a same-Apple-ID phone can link then); and stores the
// code like Issue (v4, container, owner_user, data_share, relay_share,
// transport cloudkit, transports ["cloudkit","relay"]). A pending grace
// sweep or retry is cancelled: the new code's own close sweeps. A code that
// cannot be stored closes the link it opened.
func (c *Center) IssueCloudKit(ctx context.Context, s transport.Shares) (wire.LinkPayload, string, error) {
	c.ck.mu.Lock()
	defer c.ck.mu.Unlock()
	c.ck.sweepAt, c.ck.sweepTries, c.ck.linkCloseAt, c.ck.linkCloseTries = time.Time{}, 0, time.Time{}, 0
	c.setRetired(retiredCode{}) // the new code retires every open one: their hellos read expired_code
	account, err := bounded(ctx, s.AccountStatus)
	if err != nil {
		log.Printf("hub link: iCloud account unreadable (%s): no code", shareErrorClass(err))
		return wire.LinkPayload{}, "", fmt.Errorf("link: reading the iCloud account: %w", err)
	}
	if account != transport.AccountAvailable {
		log.Printf("hub link: iCloud account %s: no code", account)
		return wire.LinkPayload{}, "", &AccountError{Account: account}
	}
	owner := c.owner(ctx)
	if owner == "" {
		return wire.LinkPayload{}, "", ErrOwnerUnknown
	}
	fields := &cloudKitFields{container: c.container, ownerUser: owner}
	if data, relay, ok := c.openPublicLink(ctx, s); ok {
		fields.dataShare, fields.relayShare = &data, &relay
	}
	p, url, err := c.issue(fields)
	if err != nil {
		// No code links, so the link just opened must not stay open.
		_ = c.closeLinkLocked(ctx, s, CloseIssueFailed)
		return wire.LinkPayload{}, "", err
	}
	c.ck.open = &openCode{nonce: p.Nonce, exp: time.Unix(p.Exp, 0).UTC()}
	return p, url, nil
}

// owner is the Mac's iCloud user record name, "" when unknown.
func (c *Center) owner(ctx context.Context) string {
	if c.ownerUser == nil {
		return ""
	}
	name, err := c.ownerUser(ctx)
	if err != nil {
		log.Printf("hub link: the Mac's iCloud user unreadable (%s)", shareErrorClass(err))
		return ""
	}
	return name
}

// openPublicLink creates the shares if needed, marks the sweep pending (a
// crash in between still closes the link) and opens the public link; false
// (no share URLs in the QR) when any of it fails.
func (c *Center) openPublicLink(ctx context.Context, s transport.Shares) (data, relay string, ok bool) {
	fail := func(step string, err error) (string, string, bool) {
		log.Printf("hub link: zone shares unavailable at %s (%s): QR without share URLs", step, shareErrorClass(err))
		c.ck.sharing = SharingUnavailable
		return "", "", false
	}
	type urls struct{ data, relay string }
	got, err := bounded(ctx, func(ctx context.Context) (urls, error) {
		d, r, err := s.EnsureShares(ctx)
		return urls{d, r}, err
	})
	if err != nil {
		return fail("ensure_shares", err)
	}
	if err := c.st.SetMeta(MetaShareSweepPending, "1"); err != nil {
		return fail("sweep_mark", err)
	}
	if err := boundedDo(ctx, func(ctx context.Context) error { return s.SetPublicLink(ctx, true) }); err != nil {
		return fail("set_public_link", err)
	}
	c.ck.sharing = SharingAvailable
	return got.data, got.relay, true
}

// Sharing is what the last CloudKit issue left: SharingAvailable,
// SharingUnavailable, or "" before any.
func (c *Center) Sharing() string {
	c.ck.mu.Lock()
	defer c.ck.mu.Unlock()
	return c.ck.sharing
}

// LinkUrgent reports that a CloudKit code is on screen or an answering
// close's grace runs: the relay pass runs at its active cadence (a late
// hello is read and refused within the grace).
func (c *Center) LinkUrgent() bool {
	c.ck.mu.Lock()
	defer c.ck.mu.Unlock()
	return c.ck.open != nil || c.now().Before(c.ck.graceEnd)
}

// CloseLink closes the CloudKit link (the Swift closeLink): every request
// still waiting is refused first (used_code after a link, expired_code at
// expiry, not_confirmed otherwise), so a waiting phone's participant is
// never swept before the owner decided. An answering close (CloseUsed,
// CloseExpired, CloseSheetClosed) retires its code, closes the public link
// now and leaves the participants to the sweep after Sweep.AnswerGrace
// (SweepShares runs it); the other closes sweep at once. The sweep closes
// the public link and removes every participant not bound to a linked
// shared phone's user_record_name; it runs only while the sweep is marked
// pending (no share call when no link was opened). A failed sweep keeps the
// mark and is retried by SweepShares after 60 s, 5, 15 and 60 min, then by
// the next close; the error is returned.
func (c *Center) CloseLink(ctx context.Context, s transport.Shares, reason CloseReason) error {
	c.ck.mu.Lock()
	defer c.ck.mu.Unlock()
	return c.closeLinkLocked(ctx, s, reason)
}

func (c *Center) closeLinkLocked(ctx context.Context, s transport.Shares, reason CloseReason) error {
	closed := c.ck.open
	c.ck.open = nil
	if err := c.refuseWaiting(reason); err != nil {
		log.Printf("hub link: waiting link requests not refused (%s, %s)", reason, shareErrorClass(err))
	}
	if !reason.answersLateHellos() {
		if err := c.sweepShares(ctx, s, reason); err != nil {
			c.scheduleSweepRetry(0)
			return err
		}
		return nil
	}
	if closed != nil {
		c.retire(closed.nonce, reason)
	}
	pending, err := c.sweepPending()
	if err != nil {
		log.Printf("hub link: share sweep mark unreadable (%s)", reason)
	} else if !pending {
		return nil
	}
	now := c.now()
	c.ck.graceEnd = now.Add(c.sweep.AnswerGrace)
	c.ck.sweepAt, c.ck.sweepTries = c.ck.graceEnd, 0
	var closeErr error
	if err := boundedDo(ctx, func(ctx context.Context) error { return s.SetPublicLink(ctx, false) }); err != nil {
		log.Printf("hub link: share link not closed (%s, %s), retried", reason, shareErrorClass(err))
		c.ck.linkCloseAt, c.ck.linkCloseTries = now.Add(linkCloseRetryDelays[0]), 1
		closeErr = fmt.Errorf("link: closing the public link: %w", err)
	}
	if c.sweep.AnswerGrace <= 0 {
		return errors.Join(closeErr, c.sweepDue(ctx, s))
	}
	return closeErr
}

// SweepShares is the CloudKit link's per-pass housekeeping, called by the
// runtime on every relay pass: it closes an open code at its expiry
// (CloseExpired), retries a failed public-link close, and runs a due
// deferred sweep (the answer grace's end, or a retry). While a code is on
// screen it does nothing else: that code's own close sweeps.
func (c *Center) SweepShares(ctx context.Context, s transport.Shares) error {
	c.ck.mu.Lock()
	defer c.ck.mu.Unlock()
	return c.sweepDue(ctx, s)
}

// sweepDue is SweepShares with ck.mu held.
func (c *Center) sweepDue(ctx context.Context, s transport.Shares) error {
	now := c.now()
	if c.ck.open != nil {
		if now.Before(c.ck.open.exp) {
			return nil
		}
		return c.closeLinkLocked(ctx, s, CloseExpired)
	}
	var linkErr error
	if !c.ck.linkCloseAt.IsZero() && !now.Before(c.ck.linkCloseAt) {
		if pending, err := c.sweepPending(); err == nil && !pending {
			c.ck.linkCloseAt = time.Time{}
		} else if err := boundedDo(ctx, func(ctx context.Context) error { return s.SetPublicLink(ctx, false) }); err != nil {
			log.Printf("hub link: share link not closed on retry (%s)", shareErrorClass(err))
			linkErr = fmt.Errorf("link: closing the public link: %w", err)
			if c.ck.linkCloseTries < len(linkCloseRetryDelays) {
				c.ck.linkCloseAt = now.Add(linkCloseRetryDelays[c.ck.linkCloseTries])
				c.ck.linkCloseTries++
			} else {
				c.ck.linkCloseAt = time.Time{}
			}
		} else {
			c.ck.linkCloseAt = time.Time{}
		}
	}
	if c.ck.sweepAt.IsZero() || now.Before(c.ck.sweepAt) {
		return linkErr
	}
	if err := c.sweepShares(ctx, s, CloseRestart); err != nil {
		c.scheduleSweepRetry(c.ck.sweepTries)
		return errors.Join(linkErr, err)
	}
	c.ck.sweepAt, c.ck.sweepTries, c.ck.linkCloseAt = time.Time{}, 0, time.Time{}
	return linkErr
}

// scheduleSweepRetry plans the retry after the tries already spent; past the
// last delay the sweep is left to the next close (the mark stays).
func (c *Center) scheduleSweepRetry(spent int) {
	if spent >= len(sweepRetryDelays) {
		c.ck.sweepAt, c.ck.sweepTries = time.Time{}, 0
		return
	}
	c.ck.sweepAt, c.ck.sweepTries = c.now().Add(sweepRetryDelays[spent]), spent+1
}

// sweepShares closes the public link and removes the participants not bound
// to a linked shared phone while the sweep is pending, then clears the mark;
// nothing when it is not pending.
func (c *Center) sweepShares(ctx context.Context, s transport.Shares, reason CloseReason) error {
	pending, err := c.sweepPending()
	if err != nil {
		return err
	}
	if !pending {
		return nil
	}
	zones, err := c.shareZones()
	if err != nil {
		return err
	}
	fail := func(step string, err error) error {
		log.Printf("hub link: share sweep failed at %s (%s, %s), retried later", step, reason, shareErrorClass(err))
		return fmt.Errorf("link: sweeping the shares: %s: %w", step, err)
	}
	if err := boundedDo(ctx, func(ctx context.Context) error { return s.SetPublicLink(ctx, false) }); err != nil {
		return fail("set_public_link", err)
	}
	bound, err := c.boundUsers()
	if err != nil {
		return fail("bound_users", err)
	}
	removed := 0
	for _, zone := range zones {
		ps, err := bounded(ctx, func(ctx context.Context) ([]transport.Participant, error) { return s.Participants(ctx, zone) })
		if err != nil {
			return fail("participants", err)
		}
		var leaving []string
		for _, p := range ps {
			if !bound[p.UserRecordName] && !slices.Contains(leaving, p.UserRecordName) {
				leaving = append(leaving, p.UserRecordName)
			}
		}
		if len(leaving) == 0 {
			continue
		}
		if err := boundedDo(ctx, func(ctx context.Context) error { return s.RemoveParticipants(ctx, zone, leaving) }); err != nil {
			return fail("remove_participants", err)
		}
		removed += len(leaving)
	}
	if err := c.st.SetMeta(MetaShareSweepPending, "0"); err != nil {
		return fail("sweep_mark", err)
	}
	log.Printf("hub link: shares swept (%s): %d participants removed", reason, removed)
	return nil
}

// HandleCloudKitHello decides a hello read from the shared RelayZone (the
// Swift handleHello): it opens and checks the hello as HandleHello does;
// a shared-scope phone whose code is valid must name, in user_record_name,
// a participant that accepted both shares — else it gets no answer at all
// (no grant, not even a refusal; the code stays usable for the owner's
// phone; a failed participant read the same); a private phone is the Mac's
// own user, so its request is bound to the owner's user record name, never
// to the name it sent. Refused codes are answered without a share call.
// s is the Shares the participants are read from (a deviation from the
// plan's signature, which had none: the center keeps no Shares).
func (c *Center) HandleCloudKitHello(ctx context.Context, s transport.Shares, rec transport.Stored) (Pending, error) {
	if c.host.RelayDeviceID == "" || rec.Zone != transport.SharedMailboxZone(c.host.RelayDeviceID) {
		log.Printf("hub link: hello %s outside the hub's RelayZone: dropped", safeName(rec.Name))
		return Pending{}, fmt.Errorf("%w: not in the RelayZone", ErrHelloDropped)
	}
	opened, err := c.openHello(rec.Zone, rec.Name, rec.Envelope)
	if err != nil {
		return Pending{}, err
	}
	payload := opened.hello.Device
	if payload.Scope == wire.ScopePrivate {
		return c.decideHello(opened, c.owner(ctx))
	}
	valid, err := c.codeValidFor(opened)
	if err != nil {
		return Pending{}, err
	}
	if valid && !c.acceptedBothShares(ctx, s, payload.UserRecordName, opened.device) {
		return Pending{}, fmt.Errorf("%w: the phone's user has not accepted both shares", ErrHelloDropped)
	}
	return c.decideHello(opened, payload.UserRecordName)
}

// codeValidFor: the hello's code would let it wait now (decideHello decides
// again in its transaction).
func (c *Center) codeValidFor(opened openedHello) (bool, error) {
	var valid bool
	err := c.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		code, ok, err := linkCodeTx(tx, opened.code.nonce)
		if err != nil {
			return err
		}
		d, _ := decide(code, ok, opened.device, c.now())
		valid = d == decisionValid
		return nil
	})
	if err != nil {
		return false, fmt.Errorf("link: reading a hello's code: %w", err)
	}
	return valid, nil
}

// acceptedBothShares: user is an accepted participant of the data and the
// relay share. Logged by device id and zone class only.
func (c *Center) acceptedBothShares(ctx context.Context, s transport.Shares, user, device string) bool {
	if user == "" {
		log.Printf("hub link: hello from phone %s names no iCloud user: no answer", device)
		return false
	}
	zones, err := c.shareZones()
	if err != nil {
		return false
	}
	for i, zone := range zones {
		ps, err := bounded(ctx, func(ctx context.Context) ([]transport.Participant, error) { return s.Participants(ctx, zone) })
		if err != nil {
			log.Printf("hub link: share participants unreadable (%s), phone %s not answered", shareErrorClass(err), device)
			return false
		}
		accepted := false
		for _, p := range ps {
			accepted = accepted || (p.UserRecordName == user && p.Accepted)
		}
		if !accepted {
			log.Printf("hub link: phone %s's user has not accepted the %s share: no answer", device, [...]string{"data", "relay"}[i])
			return false
		}
	}
	return true
}

// RemoveCloudKit is the owner's Remove on a CloudKit hub (the Swift
// remove): Unlink, then, for a shared-scope phone, its iCloud user leaves
// both shares unless another linked shared phone is on it. A failed removal
// is returned with the phone already unlinked (the gate refuses it at once);
// Unlink marked the sweep pending, so the next close removes it.
func (c *Center) RemoveCloudKit(ctx context.Context, s transport.Shares, device string) error {
	var scope, user string
	err := c.st.ReadTx(ctx, func(tx *sql.Tx) error {
		err := tx.QueryRow(`SELECT scope, user_record_name FROM devices WHERE device_id = ? COLLATE NOCASE`, device).Scan(&scope, &user)
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		return err
	})
	if err != nil {
		return fmt.Errorf("link: reading a phone: %w", err)
	}
	if err := c.Unlink(device); err != nil {
		return err
	}
	if scope != wire.ScopeShared || user == "" {
		return nil
	}
	c.ck.mu.Lock()
	defer c.ck.mu.Unlock()
	bound, err := c.boundUsers()
	if err != nil {
		return fmt.Errorf("link: reading the linked phones: %w", err)
	}
	if bound[user] {
		return nil
	}
	zones, err := c.shareZones()
	if err != nil {
		return err
	}
	for _, zone := range zones {
		if err := boundedDo(ctx, func(ctx context.Context) error { return s.RemoveParticipants(ctx, zone, []string{user}) }); err != nil {
			log.Printf("hub link: removed phone %s's participant left to the sweep (%s)", strings.ToUpper(device), shareErrorClass(err))
			return fmt.Errorf("link: removing the phone's participant: %w", err)
		}
	}
	return nil
}

// refuseWaiting refuses every request still waiting with the close's
// refusal and removes it.
func (c *Center) refuseWaiting(reason CloseReason) error {
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
			if err := refusePending(tx, p, reason.refusal(), now); err != nil {
				return err
			}
		}
		refused = all
		return nil
	})
	if err != nil {
		return err
	}
	for _, p := range refused {
		c.refusedEvent(p, reason.refusal())
	}
	if len(refused) > 0 {
		log.Printf("hub link: link closed (%s): %d waiting requests refused", reason, len(refused))
	}
	return nil
}

// retire ends an answering close's code (still unused) now: a hello under it
// during the grace is refused with the close's refusal, never kept waiting.
func (c *Center) retire(nonce string, reason CloseReason) {
	now := c.now()
	err := c.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := tx.Exec(`UPDATE link_codes SET exp = ? WHERE nonce = ? AND used_by_device IS NULL AND exp >= ?`,
			secs(now)-1, nonce, secs(now)-1)
		return err
	})
	if err != nil {
		// Such a hello waits, and the next close refuses it.
		log.Printf("hub link: closed code not retired (%s)", reason)
		return
	}
	c.setRetired(retiredCode{nonce: nonce, reason: reason.refusal()})
}

func (c *Center) setRetired(r retiredCode) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.retired = r
}

func (c *Center) sweepPending() (bool, error) {
	v, _, err := c.st.Meta(MetaShareSweepPending)
	return v == "1", err
}

// boundUsers are the linked shared phones' iCloud users.
func (c *Center) boundUsers() (map[string]bool, error) {
	bound := map[string]bool{}
	err := c.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		rows, err := tx.Query(`SELECT user_record_name FROM devices WHERE scope = ?`, wire.ScopeShared)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var name string
			if err := rows.Scan(&name); err != nil {
				return err
			}
			bound[name] = true
		}
		return rows.Err()
	})
	return bound, err
}

// shareZones are the runtime names of the two shared zones: the data zone
// and the shared RelayZone, in that order.
func (c *Center) shareZones() ([2]string, error) {
	rid := c.host.RelayDeviceID
	if rid == "" {
		return [2]string{}, ErrNoRelayID
	}
	return [2]string{transport.DataZone(rid), transport.SharedMailboxZone(rid)}, nil
}

// bounded runs one share call under ShareTimeout.
func bounded[T any](ctx context.Context, call func(context.Context) (T, error)) (T, error) {
	ctx, cancel := context.WithTimeout(ctx, ShareTimeout)
	defer cancel()
	return call(ctx)
}

func boundedDo(ctx context.Context, call func(context.Context) error) error {
	_, err := bounded(ctx, func(ctx context.Context) (struct{}, error) { return struct{}{}, call(ctx) })
	return err
}

// shareErrorClass names a share call's failure by its sentinel, never its
// text (which may carry a URL or a name).
func shareErrorClass(err error) string {
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return "timed_out"
	case errors.Is(err, context.Canceled):
		return "cancelled"
	}
	for _, s := range []error{transport.ErrUnavailable, transport.ErrForbidden, transport.ErrRateLimited,
		transport.ErrUnsupportedZone, transport.ErrUnsupportedVersion, transport.ErrHubQuota, transport.ErrMailboxQuota,
		transport.ErrRecordTooLarge, transport.ErrTokenExpired, ErrNoRelayID} {
		if errors.Is(err, s) {
			return strings.TrimPrefix(strings.TrimPrefix(s.Error(), "transport: "), "link: ")
		}
	}
	return "other"
}
