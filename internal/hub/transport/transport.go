// Package transport is the hub's neutral transport seam (spec §5, RC §3): the
// record store under the sealer. Two implementations sit behind it — the
// hosted relay (transport/relay) and, in a later phase, the CloudKit bridge —
// plus the in-memory fake (transport/memfake) the hub's tests run on.
//
// Records are last-version only. A zone has a change feed (Changes) and a
// change counter: on the hosted relay that counter is the zone's server_seq
// and a record's RecordSeq is the server_seq of its last write; on CloudKit a
// record's RecordSeq stands for its change tag, which is opaque — callers
// compare it for equality only and never with a Changes cursor. Conditional
// saves are part of Save (the spec's Conditional capability), paging is
// Batch.More (Paged) and live events are Events (Live).
//
// The E2E red line (spec §13 point 2): Save accepts only a secure.Record the
// Sealer produced. Every implementation refuses a Record with !Sealed() with
// secure.ErrUnsealed before any I/O — the whole call is refused and nothing is
// written. A record's asset file (Record.AssetPath) was checked by the Sealer
// only at seal time (its length and chunk 0), so a transport that uploads it
// must re-check it before upload or accept only files under the sealer's own
// asset directory.
package transport

import (
	"context"
	"time"

	"watchtower/internal/hub/secure"
)

// Kind names a transport.
type Kind string

// The transports.
const (
	KindRelay    Kind = "relay"
	KindCloudKit Kind = "cloudkit"
)

// ExpectMode is a save's or a delete's precondition.
type ExpectMode int

// Preconditions: none (unconditional), the record must be absent (a tombstone
// counts as absent), or the record's current RecordSeq must equal Expect.Seq.
const (
	ExpectNone ExpectMode = iota
	ExpectAbsent
	ExpectSeq
)

// Expect is a precondition; Seq is read only with ExpectSeq.
type Expect struct {
	Mode ExpectMode
	Seq  uint64
}

// SaveItem is one record to save.
type SaveItem struct {
	Record secure.Record
	Expect Expect
}

// Stored is a record as the transport holds it. In a Save outcome's Conflict
// and in a Changes batch Envelope carries the bytes; AttachmentID is the
// record's uploaded asset, or "". ServerAt is the transport's time of the
// last write where it has one; on the hosted relay, which keeps none, it is
// the writer's client_modified_at_ms, so a writer's skewed clock skews it —
// never order records by it across writers. Creator is, on CloudKit, the
// user record name of the iCloud user who created the record, as CloudKit
// reports it (CurrentUserCreator for the Mac's own user); "" where the
// transport gives none (the hosted relay, memfake by default).
type Stored struct {
	Zone, Name   string
	Envelope     []byte
	RecordSeq    uint64
	ServerAt     time.Time
	AttachmentID string
	Creator      string
}

// CurrentUserCreator is CloudKit's creator name for the current user's own
// records (CKCurrentUserDefaultName): on the Mac, the owner.
const CurrentUserCreator = "__defaultOwner__"

// Outcome is one item's result, in the order of the items. Saved is true when
// the write (or delete) took effect, with the record's new RecordSeq (a
// delete's may be 0: the hosted relay gives a tombstone a real record_seq,
// other transports may not). Saved false with Refused nil is a
// failed precondition: Conflict is the current record, or nil when there is
// none. Refused is a per-item refusal (a quota, a too-large record).
type Outcome struct {
	Saved     bool
	RecordSeq uint64
	Conflict  *Stored
	Refused   error
}

// DeleteItem is one record to delete by its wire name.
type DeleteItem struct {
	Name   string
	Expect Expect
}

// Batch is one page of a zone's changes after a cursor: the live records that
// changed and the names deleted, in change order. NewSeq is the cursor to pass
// next; More says another page follows from it. Reset marks the first page of
// a read from cursor 0 (a first pull, or the resync after ErrTokenExpired):
// the pages up to More == false list the zone's whole live set, and tombstones
// older than the expired cursor may be gone, so a consumer that mirrors the
// zone drops what it holds for the zone and does not get back.
type Batch struct {
	Changed []Stored
	Deleted []string
	NewSeq  uint64
	More    bool
	Reset   bool
}

// ControlKind is a server control event (relay proto README, Control events).
type ControlKind int

// The control kinds.
const (
	EntitlementExpired ControlKind = iota + 1
	SubscriptionMoved
	SlotRemoved
	PairingOpened
	SessionExpired
	// SlotAdded: a phone put the hub into a slot (best effort; Detail is
	// the phone's relay device id). It may repeat.
	SlotAdded
)

// Control is a server control event; Detail is the kind's detail (a device id,
// a pairing slot id, or empty).
type Control struct {
	Kind   ControlKind
	Detail string
}

// Event is one live event. Zone set means "pull this zone" (it may have
// changed); Control is a server control; Err is a transport-level failure the
// runtime should see (the connection is gone, a login failed). Resync marks
// a zone event that may stand for missed changes (the hosted relay's marker
// after a reconnect or a folded overflow): the runtime republishes what the
// phones wait for. PullNow means a silent push reached the CloudKit bridge:
// pull every zone now. Events are best effort: a consumer still pulls on its
// own backstop timer.
type Event struct {
	Zone    string
	Control *Control
	Err     error
	Resync  bool
	PullNow bool
}

// Transport is the record store under the sealer.
type Transport interface {
	Kind() Kind
	// Save writes items, which may name several zones. It refuses the whole
	// call with secure.ErrUnsealed, before any I/O, when any item's Record
	// did not come from the Sealer. Outcomes follow the items' order.
	Save(ctx context.Context, items []SaveItem) ([]Outcome, error)
	// Delete removes records of zone by wire name; outcomes follow the items.
	Delete(ctx context.Context, zone string, items []DeleteItem) ([]Outcome, error)
	// Changes returns one page of zone's changes after since (0 = from the
	// start). ErrTokenExpired means since is no longer (or was never) valid:
	// the caller resets the zone's cursor to 0 and pulls again. A consumer
	// keeps one cursor per zone; where a transport stores zone cursors itself
	// (the hosted relay's Pull) use that, not Changes, for the zone.
	Changes(ctx context.Context, zone string, since uint64) (Batch, error)
	// Events is the transport's live event stream; the same channel on
	// every call.
	Events() <-chan Event
	// Download writes the (sealed) bytes of the attachment of a record in
	// zone to dst, a hub-owned path (written 0600, replaced whole). The
	// caller names the zone from the record it holds.
	Download(ctx context.Context, zone, attachmentID, dst string) error
}

// The optional capabilities below are type-asserted by callers.

// SharedMailbox names the zone a phone's mailbox lives in. On CloudKit every
// phone of a hub shares the one RelayZone (records are routed by sender); on
// the hosted relay each phone has its own MailboxZone.
type SharedMailbox interface {
	MailboxFor(hub, phone string) string
}

// Account is the iCloud account state the CloudKit bridge reports.
type Account string

// The account states.
const (
	AccountAvailable              Account = "available"
	AccountNoAccount              Account = "no_account"
	AccountRestricted             Account = "restricted"
	AccountTemporarilyUnavailable Account = "temporarily_unavailable"
	AccountNoEntitlement          Account = "no_entitlement"
)

// Shares is CloudKit's linking surface (today's ShareService): the account
// state, the zone shares a phone accepts, the share's public link and its
// participants.
type Shares interface {
	AccountStatus(ctx context.Context) (Account, error)
	// EnsureShares creates the data and relay zone shares if missing and
	// returns their URLs (opaque: never parsed or logged).
	EnsureShares(ctx context.Context) (dataURL, relayURL string, err error)
	// SetPublicLink opens or closes the shares' public read-write link.
	SetPublicLink(ctx context.Context, open bool) error
	Participants(ctx context.Context, zone string) ([]Participant, error)
	RemoveParticipants(ctx context.Context, zone string, userRecordNames []string) error
}

// CloudUser is the CloudKit bridge's iCloud user: the Mac's own user record
// name (CKContainer.userRecordID), "" when the account has none yet.
type CloudUser interface {
	OwnerUser(ctx context.Context) (string, error)
}

// Participant is one participant of a zone share.
type Participant struct {
	UserRecordName string
	Accepted       bool
}
