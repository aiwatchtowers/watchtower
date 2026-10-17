package imap

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"slices"
	"sort"
	"time"
	"unicode/utf8"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/netsec"
)

// Syncer fetches new messages for one connected mailbox (email_accounts row)
// and stores them. One Syncer per account — mirrors gmail.Syncer, but scoped
// to a single account instead of a workspace singleton.
type Syncer struct {
	account   db.EmailAccount
	cfg       AccountConfig
	auth      Authenticator
	db        *db.DB
	appConfig *config.Config
	logger    *log.Logger

	// upsertImapMessage stores one message row. Defaults to s.db.UpsertImapMessage
	// (wired lazily in Sync, since db is only known at construction) — tests
	// override it to force a failure for a specific UID, exercising the
	// partial-batch-failure watermark behavior without needing a real DB error
	// (see sync_test.go).
	upsertImapMessage func(db.ImapMessage, string) error

	// firstSyncFrom is the window start of the last Sync when it was the
	// account's first (no last UID and no UIDVALIDITY recorded) and its
	// search succeeded; zero otherwise. A UIDVALIDITY-reset resync does not
	// count. Sync resets it; the daemon reads it via FirstSyncFrom.
	firstSyncFrom time.Time
}

// AccountID returns the email_accounts row this syncer serves.
func (s *Syncer) AccountID() int64 { return s.account.ID }

// FirstSyncFrom reports whether the last Sync was the account's first and,
// if so, the start of its SINCE window.
func (s *Syncer) FirstSyncFrom() (time.Time, bool) {
	return s.firstSyncFrom, !s.firstSyncFrom.IsZero()
}

// FetchRange stores every message received in [from, to) (IMAP SINCE/BEFORE,
// day-granular; the fetch side of the chunk convention in
// internal/historybackfill/chunk.go), uncapped, in batches of MaxMessagesPerSync. It writes no
// watermark and no auth state, and each row's synced_at is the message's own
// date, so the inbox detector never sees backfilled mail as new. The first
// error stops it.
func (s *Syncer) FetchRange(ctx context.Context, from, to time.Time) (int, error) {
	client, uidValidity, err := Dial(s.cfg, s.auth)
	if err != nil {
		return 0, fmt.Errorf("connecting account %d: %w", s.account.ID, err)
	}
	defer func() { _ = client.Close() }()

	uids, err := client.SearchRange(from, to)
	if err != nil {
		return 0, fmt.Errorf("listing account %d: %w", s.account.ID, err)
	}
	slices.Sort(uids)

	batch := s.appConfig.Imap.MaxMessagesPerSync
	if batch <= 0 {
		batch = config.DefaultImapMaxMessagesPerSync
	}
	maxBody := s.maxBodyBytes()
	upsert := s.upsertFunc()
	count := 0
	for start := 0; start < len(uids); start += batch {
		if err := ctx.Err(); err != nil {
			return count, err
		}
		msgs, err := client.FetchUIDs(uids[start:min(start+batch, len(uids))])
		if err != nil {
			return count, fmt.Errorf("fetching account %d: %w", s.account.ID, err)
		}
		for _, m := range msgs {
			// Each row keeps its own date as synced_at (backfillSyncedAt).
			if err := upsert(s.messageRow(m, uidValidity, maxBody), backfillSyncedAt(m.InternalDate, from)); err != nil {
				return count, fmt.Errorf("account %d: upsert uid %d: %w", s.account.ID, m.UID, err)
			}
			count++
		}
	}
	return count, nil
}

func (s *Syncer) messageRow(m Message, uidValidity uint32, maxBody int) db.ImapMessage {
	toJSON, _ := json.Marshal(m.To)
	ccJSON, _ := json.Marshal(m.Cc)
	return db.ImapMessage{
		AccountID: s.account.ID, UID: int64(m.UID), UIDValidity: int64(uidValidity),
		FromEmail: m.FromEmail, FromName: m.FromName,
		ToJSON: string(toJSON), CcJSON: string(ccJSON),
		Subject: m.Subject, Snippet: m.Snippet,
		BodyText: truncateUTF8(m.BodyText, maxBody), InternalDate: m.InternalDate,
		IsUnread: m.IsUnread,
	}
}

func (s *Syncer) upsertFunc() func(db.ImapMessage, string) error {
	if s.upsertImapMessage != nil {
		return s.upsertImapMessage
	}
	return s.db.UpsertImapMessage
}

// backfillSyncedAt is a backfilled row's synced_at: the message's own date
// (UTC RFC3339), or from when that is missing or unparseable. The inbox
// detector reads synced_at as "arrived since my cursor", so a backfilled row
// stamped now would surface weeks-old mail as new.
func backfillSyncedAt(internalDate string, from time.Time) string {
	if t, err := time.Parse(time.RFC3339, internalDate); err == nil {
		return t.UTC().Format(time.RFC3339)
	}
	return from.UTC().Format(time.RFC3339)
}

func (s *Syncer) maxBodyBytes() int {
	if s.appConfig.Imap.MaxBodyBytes > 0 {
		return s.appConfig.Imap.MaxBodyBytes
	}
	return config.DefaultImapMaxBodyBytes
}

// NewSyncer creates a Syncer for one connected mailbox.
// If logger is nil, a no-op logger is used.
func NewSyncer(account db.EmailAccount, cfg AccountConfig, auth Authenticator, database *db.DB, appConfig *config.Config, logger *log.Logger) *Syncer {
	if logger == nil {
		logger = log.New(io.Discard, "", 0)
	}
	return &Syncer{account: account, cfg: cfg, auth: auth, db: database, appConfig: appConfig, logger: logger}
}

// Sync connects, fetches new messages since the account's watermark, stores
// them, and advances the watermark. Returns the count of stored messages.
func (s *Syncer) Sync(ctx context.Context) (int, error) {
	s.firstSyncFrom = time.Time{}
	days := s.appConfig.Imap.InitialHistoryDays
	if days <= 0 {
		days = config.DefaultImapInitialHistoryDays
	}
	maxMsgs := s.appConfig.Imap.MaxMessagesPerSync
	if maxMsgs <= 0 {
		maxMsgs = config.DefaultImapMaxMessagesPerSync
	}
	maxBody := s.maxBodyBytes()

	lastUID, uidValidity, err := s.db.GetImapWatermark(s.account.ID)
	if err != nil {
		return 0, fmt.Errorf("reading imap watermark for account %d: %w", s.account.ID, err)
	}
	firstSync := lastUID == 0 && uidValidity == 0

	client, newUIDValidity, err := Dial(s.cfg, s.auth)
	if err != nil {
		s.recordAuthResult(err)
		return 0, fmt.Errorf("connecting account %d: %w", s.account.ID, err)
	}
	defer func() { _ = client.Close() }()
	s.recordAuthResult(nil)

	// UIDVALIDITY changed (mailbox recreated server-side): stored UIDs no
	// longer mean anything, so resync from scratch as if this were the first
	// sync — see AccountConfig/email_accounts.uidvalidity.
	if uidValidity != 0 && int64(newUIDValidity) != uidValidity {
		s.logger.Printf("imap account %d: uidvalidity changed (%d -> %d), resyncing", s.account.ID, uidValidity, newUIDValidity)
		lastUID = 0
	}

	// Two-phase list-then-fetch (mirrors gmail.Syncer): list matching UIDs
	// cheaply first (no envelope/flags/body), sort and cap that list, and only
	// then pay for a full fetch of the surviving subset — a large backlog's
	// discarded tail is never fetched over the wire at all, unlike fetching
	// everything up front and capping the already-fetched result.
	var uids []uint32
	var since time.Time
	if lastUID == 0 {
		since = time.Now().AddDate(0, 0, -days)
		uids, err = client.SearchSince(since)
	} else {
		uids, err = client.SearchNewSince(uint32(lastUID))
	}
	if err != nil {
		return 0, fmt.Errorf("listing account %d: %w", s.account.ID, err)
	}
	if firstSync {
		s.firstSyncFrom = since
	}

	// Ascending UID order so a cap below keeps the oldest, unprocessed tail
	// for the next cycle — the watermark then only advances to what was
	// actually stored (mirrors gmail.Syncer's oldest-first capping).
	slices.Sort(uids)
	if len(uids) > maxMsgs {
		s.logger.Printf("imap account %d: %d messages exceed cap %d, processing oldest %d; remainder next cycle",
			s.account.ID, len(uids), maxMsgs, maxMsgs)
		uids = uids[:maxMsgs]
	}

	msgs, err := client.FetchUIDs(uids)
	if err != nil {
		return 0, fmt.Errorf("fetching account %d: %w", s.account.ID, err)
	}
	// FetchUIDs' order isn't guaranteed by IMAP either; re-sort so the
	// ascending-UID processing order below (and its watermark logic) holds
	// regardless of what order the server returned FETCH responses in.
	sort.Slice(msgs, func(i, j int) bool { return msgs[i].UID < msgs[j].UID })

	upsert := s.upsertFunc()

	now := time.Now().UTC()
	syncedAt := now.Format(time.RFC3339)
	count := 0
	maxUID := lastUID
	stalled := false // set once an upsert fails, so maxUID stops advancing past the gap

	for _, m := range msgs {
		if ctx.Err() != nil {
			break
		}
		if err := upsert(s.messageRow(m, newUIDValidity, maxBody), syncedAt); err != nil {
			s.logger.Printf("imap account %d: upsert uid %d: %v", s.account.ID, m.UID, err)
			stalled = true
			continue
		}
		count++
		// Messages are processed in ascending-UID order, so once any upsert has
		// failed the watermark must stop advancing past that gap — a later
		// (higher-UID) message's success must not let SetImapWatermark commit a
		// value past a message that was never actually stored, or that message
		// becomes permanently unreachable (SearchNewSince starts after it).
		if stalled {
			continue
		}
		if int64(m.UID) > maxUID {
			maxUID = int64(m.UID)
		}
	}

	if maxUID > lastUID || int64(newUIDValidity) != uidValidity {
		if err := s.db.SetImapWatermark(s.account.ID, maxUID, int64(newUIDValidity)); err != nil {
			s.logger.Printf("imap account %d: advancing watermark: %v", s.account.ID, err)
		}
	}
	return count, nil
}

// recordAuthResult persists the account's connect/auth state. Pass err=nil to
// mark it healthy. Errors writing to the DB are logged but not returned —
// auth state is best-effort telemetry, mirroring gmail.Syncer.recordAuthResult.
func (s *Syncer) recordAuthResult(err error) {
	if err == nil {
		if dbErr := s.db.SetEmailAccountAuthState(s.account.ID, "ok", ""); dbErr != nil {
			s.logger.Printf("imap account %d: clear auth state: %v", s.account.ID, dbErr)
		}
		return
	}
	// A cleartext refusal carries netsec.StatusPrefix: the Desktop shows
	// it as "Stopped syncing" with what to do.
	if dbErr := s.db.SetEmailAccountAuthState(s.account.ID, "error", netsec.StatusMessage(err)); dbErr != nil {
		s.logger.Printf("imap account %d: record auth state: %v", s.account.ID, dbErr)
	}
}

// truncateUTF8 cuts body to at most maxBytes bytes, backing off to the last
// valid rune boundary — mirrors gmail.Syncer's truncateUTF8 (small enough,
// and package-private on both sides, that sharing it isn't worth a new
// exported helper).
func truncateUTF8(body string, maxBytes int) string {
	if len(body) <= maxBytes {
		return body
	}
	cut := maxBytes
	for cut > 0 && !utf8.RuneStart(body[cut]) {
		cut--
	}
	return body[:cut]
}
