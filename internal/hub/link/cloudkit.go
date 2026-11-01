package link

// Linking over CloudKit (Go hub phase 3 Task 12; the share half of the Swift
// MobileLinkCenter): the account check, the two zone shares and their public
// link window, the participant sweep, and hellos read from the shared
// RelayZone with the creator and participant checks. The share calls go
// through transport.Shares (the CloudKit bridge); share URLs are opaque and
// never parsed or logged, and log lines carry device ids, counts and error
// classes only — never a code, a URL, a nonce, a phone name or a user
// record name (FILES-01).
//
// The Swift center ran its waits (the expiry timer, the answer grace, the
// retries of a failed close) as tasks. Here they are deadlines kept in
// memory and acted on by SweepShares, which the runtime calls on every relay
// pass; the "sweep needed" mark itself is the Swift hub_meta key
// (MetaShareSweepPending), so a crash with the link open is still closed by
// the next run's CloseLink(CloseRestart).
//
// Concurrency, as on the Swift main actor whose share calls interleave: no
// lock is held across a bridge call except linkMu, which lets one public-link
// write run at a time (the Swift single link writer, #262). The share state
// (ckState) is read and changed under ck.mu for a moment only, so LinkUrgent
// and Sharing never wait on the bridge. Interleavings are settled by
// compare-and-set: a sweep clears the mark only if no unlink marked it again
// meanwhile (the sweep epoch in hub_meta, the Swift sweepEpoch); a deferred
// sweep stands down once a code is being issued or on screen (the Swift
// yieldsToIssue); a public-link write yields to a newer wanted state; an
// owner lookup or an issue that ran across an account change is not kept
// (the account epoch, the Swift ownerEpoch).

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// CloudKitContainer is the CloudKit container a CloudKit code names: the
// Kit's WatchtowerCloud.containerID (a phone refuses a code of another
// container, wrong_container).
const CloudKitContainer = "iCloud.com.aiwatchtowers.watchtower"

// MetaShareSweepPending is the Swift hub's hub_meta key: "1" while the
// shares need a close-and-sweep (from just before the public link opens, or
// after an unlink of a shared phone) until a sweep succeeds; "0" after it.
const MetaShareSweepPending = "share_sweep_pending"

// MetaShareSweepEpoch counts the marks (Go only; absent reads 0): every
// write of the pending mark bumps it in the same transaction, and a sweep
// clears the mark only while it still reads the epoch the sweep started on.
const MetaShareSweepEpoch = "share_sweep_epoch"

// ShareTimeout bounds every share call (the Swift MobileHubService
// defaultCloudTimeout): offline CloudKit waits for connectivity.
const ShareTimeout = 30 * time.Second

// Sweep is the participant sweep's timing.
type Sweep struct {
	// AnswerGrace is how long an answering close (CloseUsed, CloseExpired,
	// CloseSheetClosed) keeps the unbound participants: a phone that
	// accepted the public link but had not written its hello yet still
	// reads its refusal in the data zone. The public link closes at once.
	// Zero in a Config means DefaultSweep.
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

// voidsCode: the close ends a code being issued too (the Swift voidsCode),
// so its public-link close does not yield to that code.
func (r CloseReason) voidsCode() bool { return r == CloseIssueFailed || r == CloseAccountChanged }

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

// AccountUnreadable is the account state when the bridge could not report
// one (the Swift CloudAvailability.unavailable for a failed read).
const AccountUnreadable transport.Account = "unavailable"

var (
	// ErrOwnerUnknown: the Mac's iCloud user could not be read; no code.
	ErrOwnerUnknown = errors.New("link: the Mac's iCloud user is unknown")
	// ErrAccountChanged: the Mac's iCloud account changed while a code was
	// being issued; the code would name the old user, so it was not issued
	// and the link it opened was closed.
	ErrAccountChanged = errors.New("link: the iCloud account changed")
	// ErrNoRelayID: the center has no relay device id to name the zones.
	ErrNoRelayID = errors.New("link: no relay device id names the hub's zones")
	// errSuperseded: a public-link open that a close replaced meanwhile.
	errSuperseded = errors.New("link: the public link was closed meanwhile")
)

// AccountError refuses a CloudKit code: the Mac's iCloud account is not
// available. Account is its state (AccountUnreadable when the read failed,
// with Err the failure), the error class.
type AccountError struct {
	Account transport.Account
	Err     error
}

func (e *AccountError) Error() string { return "link: the iCloud account is " + string(e.Account) }

func (e *AccountError) Unwrap() error { return e.Err }

// ckState is the CloudKit link's state, guarded by mu (never held across a
// bridge call, and never held while taking Center.mu).
type ckState struct {
	mu sync.Mutex
	// open is the code on screen, nil once it was used, expired or closed.
	open *openCode
	// issuing counts the IssueCloudKit calls running (the Swift issuing).
	issuing int
	// graceEnd: an answering close's grace runs until then.
	graceEnd time.Time
	// sweepAt: a deferred sweep (the grace's end, a retry, an unlink) is due
	// then; zero when none. sweepTries counts the retries spent.
	sweepAt    time.Time
	sweepTries int
	// linkCloseAt: a failed public-link close is retried then; zero when
	// none. linkCloseTries counts the retries spent.
	linkCloseAt    time.Time
	linkCloseTries int
	// sharing: what the last issue left (SharingAvailable/Unavailable), ""
	// before any.
	sharing string
	// owner is the Mac's iCloud user as last read, "" when not cached;
	// accountEpoch counts the account changes (the Swift ownerEpoch).
	owner        string
	accountEpoch uint64
	// linkWanted is the public link the center wants (the Swift linkWanted).
	linkWanted bool
}

type openCode struct {
	nonce string
	exp   time.Time
}

// retiredCode is the code an answering close retired and the refusal a
// hello under it reads; empty when none.
type retiredCode struct{ nonce, reason string }

// IssueCloudKit makes a CloudKit QR code (the Swift issueCode): it refuses
// without an available iCloud account (*AccountError, no share call; a
// failed read is AccountUnreadable) or the Mac's user (ErrOwnerUnknown; read
// from s, a transport.CloudUser such as the CloudKit client, and cached
// until the account changes); creates the zone shares if missing, marks the
// sweep pending and opens their public link — a failure there leaves the
// share URLs out (only a same-Apple-ID phone can link then); then checks
// the owner again: an account change meanwhile (AccountChanged, or another
// owner) closes the link with CloseAccountChanged and returns
// ErrAccountChanged. Otherwise it stores the code like Issue (v4, container,
// owner_user, data_share, relay_share, transport cloudkit, transports
// ["cloudkit","relay"]). A pending grace sweep or retry is cancelled: the
// new code's own close sweeps. A code that cannot be stored closes the link
// it opened.
func (c *Center) IssueCloudKit(ctx context.Context, s transport.Shares) (wire.LinkPayload, string, error) {
	c.ck.mu.Lock()
	c.ck.issuing++
	c.ck.sweepAt, c.ck.sweepTries, c.ck.linkCloseAt, c.ck.linkCloseTries = time.Time{}, 0, time.Time{}, 0
	epoch := c.ck.accountEpoch
	c.ck.mu.Unlock()
	defer func() {
		c.ck.mu.Lock()
		c.ck.issuing--
		c.ck.mu.Unlock()
	}()
	c.setRetired(retiredCode{}) // the new code retires every open one: their hellos read expired_code
	account, err := bounded(ctx, s.AccountStatus)
	if err != nil {
		log.Printf("hub link: iCloud account unreadable (%s): no code", shareErrorClass(err))
		return wire.LinkPayload{}, "", &AccountError{Account: AccountUnreadable, Err: err}
	}
	if account != transport.AccountAvailable {
		log.Printf("hub link: iCloud account %s: no code", account)
		return wire.LinkPayload{}, "", &AccountError{Account: account}
	}
	owner := c.owner(ctx, s)
	if owner == "" {
		return wire.LinkPayload{}, "", ErrOwnerUnknown
	}
	fields := &cloudKitFields{container: c.container, ownerUser: owner}
	if data, relay, ok := c.openPublicLink(ctx, s); ok {
		fields.dataShare, fields.relayShare = &data, &relay
	}
	if c.accountMoved(ctx, s, epoch, owner) {
		log.Printf("hub link: the iCloud account changed while a code was issued: link closed, no code")
		_ = c.closeLink(ctx, s, CloseAccountChanged, nil)
		return wire.LinkPayload{}, "", ErrAccountChanged
	}
	p, url, err := c.issue(fields)
	if err != nil {
		// No code links, so the link just opened must not stay open.
		_ = c.closeLink(ctx, s, CloseIssueFailed, nil)
		return wire.LinkPayload{}, "", err
	}
	c.ck.mu.Lock()
	c.ck.open = &openCode{nonce: p.Nonce, exp: time.Unix(p.Exp, 0).UTC()}
	c.ck.mu.Unlock()
	return p, url, nil
}

// owner is the Mac's iCloud user record name, "" when unknown (s is no
// transport.CloudUser, or the lookup failed). A name read across an account
// change is used but not cached.
func (c *Center) owner(ctx context.Context, s transport.Shares) string {
	c.ck.mu.Lock()
	cached, epoch := c.ck.owner, c.ck.accountEpoch
	c.ck.mu.Unlock()
	if cached != "" {
		return cached
	}
	name, ok := c.readOwner(ctx, s)
	if !ok {
		return ""
	}
	c.ck.mu.Lock()
	if epoch == c.ck.accountEpoch {
		c.ck.owner = name
	}
	c.ck.mu.Unlock()
	return name
}

// readOwner asks the bridge for the Mac's user; false when it cannot tell.
func (c *Center) readOwner(ctx context.Context, s transport.Shares) (string, bool) {
	u, ok := s.(transport.CloudUser)
	if !ok {
		return "", false
	}
	name, err := bounded(ctx, u.OwnerUser)
	if err != nil {
		log.Printf("hub link: the Mac's iCloud user unreadable (%s)", shareErrorClass(err))
		return "", false
	}
	return name, name != ""
}

// accountMoved: the account changed since epoch, or the bridge now names
// another owner than owner (a failed re-read leaves it to the epoch). A
// moved owner drops the cache.
func (c *Center) accountMoved(ctx context.Context, s transport.Shares, epoch uint64, owner string) bool {
	now, ok := c.readOwner(ctx, s)
	c.ck.mu.Lock()
	defer c.ck.mu.Unlock()
	if ok && now != owner {
		c.ck.owner = ""
		c.ck.accountEpoch++
	}
	return c.ck.accountEpoch != epoch
}

// AccountChanged handles the bridge's account_changed event (the Swift
// account-change close): the cached owner is dropped, a lookup or an issue
// running across it is not kept, and the open code and its link are closed
// with CloseAccountChanged (waiting requests refused not_confirmed, the
// participants swept at once).
func (c *Center) AccountChanged(ctx context.Context, s transport.Shares) error {
	c.ck.mu.Lock()
	c.ck.owner = ""
	c.ck.accountEpoch++
	c.ck.mu.Unlock()
	log.Printf("hub link: the iCloud account changed: the open link is closed")
	return c.CloseLink(ctx, s, CloseAccountChanged)
}

// openPublicLink creates the shares if needed, marks the sweep pending (a
// crash in between still closes the link) and opens the public link; false
// (no share URLs in the QR) when any of it fails.
func (c *Center) openPublicLink(ctx context.Context, s transport.Shares) (data, relay string, ok bool) {
	fail := func(step string, err error) (string, string, bool) {
		log.Printf("hub link: zone shares unavailable at %s (%s): QR without share URLs", step, shareErrorClass(err))
		c.setSharing(SharingUnavailable)
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
	if err := c.st.WithTx(ctx, markSweepTx); err != nil {
		return fail("sweep_mark", err)
	}
	if written, err := c.setLink(ctx, s, true, CloseRestart); err != nil {
		return fail("set_public_link", err)
	} else if !written {
		return fail("set_public_link", errSuperseded)
	}
	c.setSharing(SharingAvailable)
	return got.data, got.relay, true
}

func (c *Center) setSharing(v string) {
	c.ck.mu.Lock()
	defer c.ck.mu.Unlock()
	c.ck.sharing = v
}

// Sharing is what the last CloudKit issue left: SharingAvailable,
// SharingUnavailable, or "" before any. It never waits on the bridge.
func (c *Center) Sharing() string {
	c.ck.mu.Lock()
	defer c.ck.mu.Unlock()
	return c.ck.sharing
}

// LinkUrgent reports that a CloudKit code is on screen or an answering
// close's grace runs: the relay pass runs at its active cadence (a late
// hello is read and refused within the grace). It never waits on the
// bridge.
func (c *Center) LinkUrgent() bool {
	c.ck.mu.Lock()
	defer c.ck.mu.Unlock()
	return c.ck.open != nil || c.now().Before(c.ck.graceEnd)
}

// setLink writes the public link through the one writer (the Swift
// setPublicLink(open:reason:)): open or closed becomes the wanted state; a
// close yields to a code being issued unless reason voids it; the write
// runs only if it is still wanted when its turn comes (a newer wanted state
// supersedes it). written false: no call was made.
func (c *Center) setLink(ctx context.Context, s transport.Shares, open bool, reason CloseReason) (bool, error) {
	c.ck.mu.Lock()
	if !open && c.ck.issuing > 0 && !reason.voidsCode() {
		c.ck.mu.Unlock()
		return false, nil
	}
	c.ck.linkWanted = open
	c.ck.mu.Unlock()
	c.linkMu.Lock()
	defer c.linkMu.Unlock()
	c.ck.mu.Lock()
	wanted := c.ck.linkWanted
	c.ck.mu.Unlock()
	if wanted != open {
		return false, nil
	}
	if err := boundedDo(ctx, func(ctx context.Context) error { return s.SetPublicLink(ctx, open) }); err != nil {
		return false, err
	}
	return true, nil
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
	closed := c.ck.open
	c.ck.open = nil
	c.ck.mu.Unlock()
	return c.closeLink(ctx, s, reason, closed)
}

// closeLink is CloseLink once the open code (closed, or nil) was taken.
func (c *Center) closeLink(ctx context.Context, s transport.Shares, reason CloseReason, closed *openCode) error {
	if err := c.refuseWaiting(reason); err != nil {
		log.Printf("hub link: waiting link requests not refused (%s, %s)", reason, shareErrorClass(err))
	}
	if !reason.answersLateHellos() {
		if _, err := c.sweepShares(ctx, s, reason, false); err != nil {
			c.ck.mu.Lock()
			c.scheduleSweepRetry(0)
			c.ck.mu.Unlock()
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
	c.ck.mu.Lock()
	c.ck.graceEnd = c.now().Add(c.sweep.AnswerGrace)
	c.ck.sweepAt, c.ck.sweepTries = c.ck.graceEnd, 0
	c.ck.mu.Unlock()
	if _, err := c.setLink(ctx, s, false, reason); err != nil {
		log.Printf("hub link: share link not closed (%s, %s), retried", reason, shareErrorClass(err))
		c.ck.mu.Lock()
		c.ck.linkCloseAt, c.ck.linkCloseTries = c.now().Add(linkCloseRetryDelays[0]), 1
		c.ck.mu.Unlock()
		return fmt.Errorf("link: closing the public link: %w", err)
	}
	return nil
}

// SweepShares is the CloudKit link's per-pass housekeeping, called by the
// runtime on every relay pass: it closes an open code at its expiry
// (CloseExpired), retries a failed public-link close, and runs a due
// deferred sweep (the answer grace's end, a retry, an unlink). While a code
// is being issued or on screen it does nothing else: that code's own close
// sweeps.
func (c *Center) SweepShares(ctx context.Context, s transport.Shares) error {
	now := c.now()
	c.ck.mu.Lock()
	if open := c.ck.open; open != nil {
		if now.Before(open.exp) {
			c.ck.mu.Unlock()
			return nil
		}
		c.ck.open = nil
		c.ck.mu.Unlock()
		return c.closeLink(ctx, s, CloseExpired, open)
	}
	if c.ck.issuing > 0 {
		c.ck.mu.Unlock()
		return nil
	}
	linkDue := !c.ck.linkCloseAt.IsZero() && !now.Before(c.ck.linkCloseAt)
	sweepDue := !c.ck.sweepAt.IsZero() && !now.Before(c.ck.sweepAt)
	c.ck.mu.Unlock()

	var linkErr error
	if linkDue {
		linkErr = c.retryLinkClose(ctx, s, now)
	}
	if !sweepDue {
		return linkErr
	}
	cleared, err := c.sweepShares(ctx, s, CloseRestart, true)
	c.ck.mu.Lock()
	defer c.ck.mu.Unlock()
	switch {
	case err != nil:
		c.scheduleSweepRetry(c.ck.sweepTries)
		return errors.Join(linkErr, err)
	case cleared:
		c.ck.sweepAt, c.ck.sweepTries, c.ck.linkCloseAt = time.Time{}, 0, time.Time{}
	default:
		// Stood down for a code, or an unlink marked the sweep again
		// meanwhile: the next pass looks again.
		c.ck.sweepAt = c.now()
	}
	return linkErr
}

// retryLinkClose retries a failed public-link close while the sweep is
// still pending, after each of linkCloseRetryDelays.
func (c *Center) retryLinkClose(ctx context.Context, s transport.Shares, now time.Time) error {
	if pending, err := c.sweepPending(); err == nil && !pending {
		c.ck.mu.Lock()
		c.ck.linkCloseAt = time.Time{}
		c.ck.mu.Unlock()
		return nil
	}
	_, err := c.setLink(ctx, s, false, CloseRestart)
	c.ck.mu.Lock()
	defer c.ck.mu.Unlock()
	if err == nil {
		c.ck.linkCloseAt = time.Time{}
		return nil
	}
	log.Printf("hub link: share link not closed on retry (%s)", shareErrorClass(err))
	if c.ck.linkCloseTries < len(linkCloseRetryDelays) {
		c.ck.linkCloseAt = now.Add(linkCloseRetryDelays[c.ck.linkCloseTries])
		c.ck.linkCloseTries++
	} else {
		c.ck.linkCloseAt = time.Time{}
	}
	return fmt.Errorf("link: closing the public link: %w", err)
}

// scheduleSweepRetry plans the retry after the tries already spent; past the
// last delay the sweep is left to the next close (the mark stays). ck.mu is
// held.
func (c *Center) scheduleSweepRetry(spent int) {
	if spent >= len(sweepRetryDelays) {
		c.ck.sweepAt, c.ck.sweepTries = time.Time{}, 0
		return
	}
	c.ck.sweepAt, c.ck.sweepTries = c.now().Add(sweepRetryDelays[spent]), spent+1
}

// sweepSoon makes a deferred sweep due at the next pass (an unlinked shared
// phone's participant goes at once, as in Swift; RemoveCloudKit removes it
// even sooner).
func (c *Center) sweepSoon() {
	c.ck.mu.Lock()
	defer c.ck.mu.Unlock()
	if now := c.now(); c.ck.sweepAt.IsZero() || c.ck.sweepAt.After(now) {
		c.ck.sweepAt, c.ck.sweepTries = now, 0
	}
}

// sweepSnapshot is what a sweep starts from, read in one transaction: the
// mark, its epoch and the linked shared phones' users.
type sweepSnapshot struct {
	pending bool
	epoch   uint64
	bound   map[string]bool
}

func (c *Center) readSweep(ctx context.Context) (sweepSnapshot, error) {
	snap := sweepSnapshot{bound: map[string]bool{}}
	err := c.st.ReadTx(ctx, func(tx *sql.Tx) error {
		v, _, err := state.MetaTx(tx, MetaShareSweepPending)
		if err != nil {
			return err
		}
		snap.pending = v == "1"
		if snap.epoch, err = sweepEpochTx(tx); err != nil {
			return err
		}
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
			snap.bound[name] = true
		}
		return rows.Err()
	})
	return snap, err
}

// sweepShares closes the public link and removes the participants not bound
// to a linked shared phone while the sweep is pending, then clears the mark
// — only if its epoch did not move meanwhile (an unlink during the sweep
// keeps it pending). A deferred sweep stands down, the mark kept, once a
// code is being issued or on screen. cleared: the mark was cleared (or was
// not pending).
func (c *Center) sweepShares(ctx context.Context, s transport.Shares, reason CloseReason, deferred bool) (bool, error) {
	snap, err := c.readSweep(ctx)
	if err != nil {
		return false, fmt.Errorf("link: reading the share sweep: %w", err)
	}
	if !snap.pending {
		return true, nil
	}
	zones, err := c.shareZones()
	if err != nil {
		return false, err
	}
	yields := func() bool {
		if !deferred {
			return false
		}
		c.ck.mu.Lock()
		defer c.ck.mu.Unlock()
		return c.ck.issuing > 0 || c.ck.open != nil
	}
	fail := func(step string, err error) (bool, error) {
		log.Printf("hub link: share sweep failed at %s (%s, %s), retried later", step, reason, shareErrorClass(err))
		return false, fmt.Errorf("link: sweeping the shares: %s: %w", step, err)
	}
	if yields() {
		return false, nil
	}
	if written, err := c.setLink(ctx, s, false, reason); err != nil {
		return fail("set_public_link", err)
	} else if !written {
		return false, nil // a code being issued keeps its link: its own close sweeps
	}
	removed := 0
	for _, zone := range zones {
		if yields() {
			return false, nil
		}
		ps, err := bounded(ctx, func(ctx context.Context) ([]transport.Participant, error) { return s.Participants(ctx, zone) })
		if err != nil {
			return fail("participants", err)
		}
		var leaving []string
		for _, p := range ps {
			if !snap.bound[p.UserRecordName] && !slices.Contains(leaving, p.UserRecordName) {
				leaving = append(leaving, p.UserRecordName)
			}
		}
		if len(leaving) == 0 {
			continue
		}
		if yields() {
			return false, nil
		}
		if err := boundedDo(ctx, func(ctx context.Context) error { return s.RemoveParticipants(ctx, zone, leaving) }); err != nil {
			return fail("remove_participants", err)
		}
		removed += len(leaving)
	}
	var cleared bool
	err = c.st.WithTx(ctx, func(tx *sql.Tx) error {
		epoch, err := sweepEpochTx(tx)
		if err != nil || epoch != snap.epoch {
			return err
		}
		cleared = true
		return state.SetMetaTx(tx, MetaShareSweepPending, "0")
	})
	if err != nil {
		return fail("sweep_mark", err)
	}
	if !cleared {
		log.Printf("hub link: shares swept (%s): %d participants removed; marked again meanwhile, kept pending", reason, removed)
		return false, nil
	}
	log.Printf("hub link: shares swept (%s): %d participants removed", reason, removed)
	return true, nil
}

// markSweepTx marks the sweep pending and bumps its epoch, in tx.
func markSweepTx(tx *sql.Tx) error {
	epoch, err := sweepEpochTx(tx)
	if err != nil {
		return err
	}
	if err := state.SetMetaTx(tx, MetaShareSweepEpoch, strconv.FormatUint(epoch+1, 10)); err != nil {
		return err
	}
	return state.SetMetaTx(tx, MetaShareSweepPending, "1")
}

func sweepEpochTx(tx *sql.Tx) (uint64, error) {
	v, ok, err := state.MetaTx(tx, MetaShareSweepEpoch)
	if err != nil || !ok {
		return 0, err
	}
	n, err := strconv.ParseUint(v, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("hub_meta %s unreadable: %w", MetaShareSweepEpoch, err)
	}
	return n, nil
}

// HandleCloudKitHello decides a hello read from the shared RelayZone (the
// Swift handleHello): it opens and checks the hello as HandleHello does,
// then runs the creator check (creatorMatches) — a hello another iCloud
// user wrote gets no answer at all (no grant, not even a refusal; the code
// stays usable). A shared-scope phone whose code is valid must also name,
// in user_record_name, a participant that accepted both shares (else no
// answer; a failed participant read the same); a private phone is the
// Mac's own user, so its request is bound to the owner's user record name,
// never to the name it sent. Refused codes are answered without a share
// call. s is the Shares the participants and the owner are read from (a
// deviation from the plan's signature, which had none: the center keeps no
// Shares).
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
	var owner string
	if payload.Scope == wire.ScopePrivate {
		owner = c.owner(ctx, s)
	}
	if !creatorMatches(payload, rec.Creator, owner) {
		log.Printf("hub link: hello %s not written by its phone's user: no answer", safeName(rec.Name))
		return Pending{}, fmt.Errorf("%w: written by another iCloud user", ErrHelloDropped)
	}
	if payload.Scope == wire.ScopePrivate {
		return c.decideHello(opened, owner)
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

// creatorMatches is the Swift creatorMatches: a shared phone's record was
// created by the phone's own user (the user_record_name it sent); a private
// phone's by the Mac's user — the current-user name, the owner's own
// record name, or no creator at all (a stranger on a share cannot pass as
// a same-Apple-ID phone). owner is the Mac's user ("" = unknown).
func creatorMatches(payload wire.DevicePayload, creator, owner string) bool {
	if payload.Scope != wire.ScopePrivate {
		return creator != "" && creator == payload.UserRecordName
	}
	if creator == "" || creator == transport.CurrentUserCreator {
		return true
	}
	return owner != "" && creator == owner
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

// RemoveCloudKit is the owner's Remove on a CloudKit hub, and the phone's
// own unlink (the Swift remove and handleLinkedRewrite): Unlink, then, for a
// shared-scope phone, its iCloud user leaves both shares at once unless
// another linked shared phone is on it. A failed removal is returned with
// the phone already unlinked (the gate refuses it at once); Unlink marked
// the sweep pending and due, so the next pass removes it.
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
	snap, err := c.readSweep(ctx)
	if err != nil {
		return fmt.Errorf("link: reading the linked phones: %w", err)
	}
	if snap.bound[user] {
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

// shareZones are the runtime names of the two shared zones: the data zone
// and the shared RelayZone, in that order.
func (c *Center) shareZones() ([2]string, error) {
	rid := c.host.RelayDeviceID
	if rid == "" {
		log.Printf("hub link: no relay device id names the hub's zones: share call refused")
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
	case errors.Is(err, errSuperseded):
		return "superseded"
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
