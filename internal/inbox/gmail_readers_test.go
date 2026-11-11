package inbox

import (
	"io/fs"
	"os"
	"sort"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// gmailReaderSides pins every non-test Go file that names the
// gmail_messages table to its side of INBOX-02's reader rule
// (docs/inventory/inbox-pulse.md): a reader that treats a row as
// something that happened to the owner skips the owner's own sent rows
// ("skip"), a reader that treats a row as knowledge keeps them ("keep"),
// the auto-resolve predicate reads only the owner's sent rows ("answer"),
// and writers, deletes and purges are "lifecycle".
var gmailReaderSides = map[string]string{
	// detectGmailAccount (via GmailMessagesSyncedAfter).
	"internal/inbox/gmail_detector.go": "skip",
	// MailNewsFloor, CountMailAfter (gmail.new_messages).
	"internal/db/automation_event_sources.go": "skip",
	// seedGmailSenders (correspondents).
	"internal/memory/seed.go": "skip",

	// GmailItemsAnsweredByOwner (reads only the owner's sent rows).
	"internal/db/gmail_sent.go": "answer",

	// gmailSource.Changed/Keys/Build.
	"internal/kb/source_mail.go": "keep",
	// Media parent key lookup.
	"internal/kb/media.go": "keep",
	// gmailScanQuery.
	"internal/doclinks/linkscan/scan.go": "keep",
	// GmailMessageSender, GmailMessageExists, ListGmailThreadsForExtract
	// (memory extraction and ideas email digests).
	"internal/db/memory.go": "keep",
	// Comments over the internal/db/memory.go readers.
	"internal/memory/gmail_extract.go": "keep",
	"internal/memory/provenance.go":    "keep",
	// ListLocalEmails, GetLocalEmail (list_emails/get_email, sent key).
	"internal/db/emails_read.go": "keep",
	// list_emails/get_email tool texts naming the table (reads through
	// internal/db/emails_read.go).
	"internal/tools/emails.go": "keep",

	// upsertGmailMessage (writer), GmailMessagesSyncedAfter (detector
	// feed), GmailStoredIDs + DeleteGmailMessages (SRCDEL), ClearGmailData.
	"internal/db/gmail.go": "lifecycle",
	// PURGE-02 gmail step (account_id = ?).
	"internal/db/account_purge_steps.go": "lifecycle",
	// DeleteGoogleAccount cascade (comment).
	"internal/db/google_accounts.go": "lifecycle",
	// Clear confirmation row count.
	"cmd/gmail.go": "lifecycle",
	// Comment only.
	"cmd/google_legacy.go": "lifecycle",
}

// TestInbox02_EveryGmailReaderHasASide fails when a non-test Go file
// starts (or stops) naming gmail_messages without a pinned side, so a new
// reader cannot silently count the owner's own sent mail as something
// that happened to the owner (or drop it from knowledge).
func TestInbox02_EveryGmailReaderHasASide(t *testing.T) {
	repo, err := os.OpenRoot("../..")
	require.NoError(t, err)
	t.Cleanup(func() { _ = repo.Close() })
	found := map[string]bool{}
	for _, dir := range []string{"internal", "cmd"} {
		require.NoError(t, fs.WalkDir(repo.FS(), dir, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() || !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") {
				return nil
			}
			body, err := fs.ReadFile(repo.FS(), p)
			if err != nil {
				return err
			}
			if strings.Contains(string(body), "gmail_messages") {
				found[p] = true
			}
			return nil
		}))
	}

	var unclassified, stale []string
	for f := range found {
		if _, ok := gmailReaderSides[f]; !ok {
			unclassified = append(unclassified, f)
		}
	}
	for f := range gmailReaderSides {
		if !found[f] {
			stale = append(stale, f)
		}
	}
	sort.Strings(unclassified)
	sort.Strings(stale)
	for _, f := range unclassified {
		t.Errorf("classify %s: skip, keep or lifecycle (docs/inventory/inbox-pulse.md INBOX-02)", f)
	}
	for _, f := range stale {
		t.Errorf("%s no longer names gmail_messages: remove it from gmailReaderSides", f)
	}
}
