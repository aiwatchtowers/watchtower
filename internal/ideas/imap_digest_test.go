package ideas

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// seedImapMailbox inserts an IMAP email_accounts row and returns its id.
func seedImapMailbox(t *testing.T, d *db.DB) int64 {
	t.Helper()
	id, err := d.CreateEmailAccount(db.EmailAccount{Provider: "imap", EmailAddress: "me@example.com",
		Host: "imap.example.com", Port: 993, Security: "ssl", Folder: "INBOX"})
	require.NoError(t, err)
	return id
}

// seedImapMessage stores one IMAP message (uidvalidity 1) dated at.
func seedImapMessage(t *testing.T, d *db.DB, accountID, uid int64, subject, body string, at time.Time) {
	t.Helper()
	require.NoError(t, d.UpsertImapMessage(db.ImapMessage{
		AccountID: accountID, UID: uid, UIDValidity: 1, FromEmail: "ann@example.com", FromName: "Ann",
		Subject: subject, BodyText: body, InternalDate: at.UTC().Format(time.RFC3339),
	}, at.UTC().Format(time.RFC3339)))
}

func imapTag(accountID, uid int64) string { return fmt.Sprintf("imap:%d:1-%d", accountID, uid) }

// #615: an IMAP-only install mines its mailbox — one stream_digests row with
// source 'imap', a ref per message, the hallucinated ref dropped (IDEA-02),
// and the mailbox's own floor advanced to the newest rendered message
// (IDEA-01).
func TestRunEmailDigests_ImapMailboxMinedAndFloorAdvances(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Truncate(time.Second)
	acct := seedImapMailbox(t, d)
	require.NoError(t, d.SetIdeasImapFloor(acct, float64(base.Unix())))
	seedImapMessage(t, d, acct, 7, "Vendor", "We should try a new vendor.", base.Add(10*time.Second))
	seedImapMessage(t, d, acct, 8, "Launch", "We decided to launch Friday.", base.Add(20*time.Second))

	var prompt string
	gen := &fakeGen{reply: func(user string) (string, error) {
		prompt = user
		return fmt.Sprintf(`{"topics":[{"title":"Vendor","summary":"s",
			"ideas":[{"text":"try a vendor","author":"Ann","ref":%q},{"text":"invented","author":"X","ref":"imap:%d:1-99"}],
			"decisions":[{"text":"launch Friday","author":"Ann","ref":%q}]}]}`, imapTag(acct, 7), acct, imapTag(acct, 8)), nil
	}}
	require.NoError(t, New(d, testCfg(), gen, testLogger()).runEmailDigests(context.Background(), time.Time{}))
	assert.Equal(t, 1, gen.calls)
	assert.Contains(t, prompt, "("+imapTag(acct, 7)+")")

	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	require.Len(t, digests, 1)
	assert.Equal(t, "imap", digests[0].Source)
	assert.Equal(t, acct, digests[0].AccountID)
	assert.Contains(t, digests[0].TopicsJSON, imapTag(acct, 7))
	assert.Contains(t, digests[0].TopicsJSON, imapTag(acct, 8))
	assertNoStreamDigestCites(t, d, fmt.Sprintf("imap:%d:1-99", acct))

	floor, err := d.IdeasImapFloor(acct)
	require.NoError(t, err)
	assert.Equal(t, float64(base.Add(20*time.Second).Unix()), floor)
}

// #615: a never-initialized mailbox floor is stamped at its newest stored
// message and nothing is mined — the Gmail self-init, no backfill.
func TestRunEmailDigests_ImapFloorZeroInitializesAndSkips(t *testing.T) {
	d := newTestDB(t)
	at := time.Now().Add(-time.Hour).Truncate(time.Second)
	acct := seedImapMailbox(t, d)
	seedImapMessage(t, d, acct, 1, "Old", "old mail", at.Add(-time.Hour))
	seedImapMessage(t, d, acct, 2, "New", "new mail", at)

	gen := &fakeGen{reply: func(string) (string, error) {
		t.Fatal("generator must not be called on the init pass")
		return "", nil
	}}
	require.NoError(t, New(d, testCfg(), gen, testLogger()).runEmailDigests(context.Background(), time.Time{}))
	floor, err := d.IdeasImapFloor(acct)
	require.NoError(t, err)
	assert.Equal(t, float64(at.Unix()), floor)
}

// #615: an imap stream digest's ref survives the consolidator's validation and
// lands as a mention whose source is 'imap' (accepted by idea_mentions' CHECK).
func TestConsolidate_ImapRefMentionSourceIsImap(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	ref := "imap:3:1-42"
	seedStreamDigestIdeas(t, d, "imap", 3, []streamTopic{{Title: "Vendor", Summary: "s",
		Ideas: []streamCandidate{{Text: "try a new vendor", Author: "Ann", Ref: ref}}}})

	gen := &fakeGen{reply: func(string) (string, error) {
		return fmt.Sprintf(`{"ops":[{"op":"new_idea","title":"New vendor","essence":"e",
			"mentions":[{"source":"gmail","ref":%q,"quote":"try a new vendor","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]}]}`, ref), nil
	}}
	proposed, _, err := New(d, testCfg(), gen, testLogger()).runConsolidate(context.Background(), time.Time{}, time.Time{})
	require.NoError(t, err)
	assert.Equal(t, 1, proposed)

	ideas, err := d.ListIdeas(db.IdeaFilter{})
	require.NoError(t, err)
	require.Len(t, ideas, 1)
	mentions, err := d.ListIdeaMentions(ideas[0].ID)
	require.NoError(t, err)
	require.Len(t, mentions, 1)
	assert.Equal(t, "imap", mentions[0].Source)
	assert.Equal(t, ref, mentions[0].Ref)
}

// imapFloorWatchGen answers stage-1 calls like stage1Gen and records the
// mailbox's stored floor at each call.
type imapFloorWatchGen struct {
	stage1Gen
	d    *db.DB
	acct int64
	seen []float64
}

func (g *imapFloorWatchGen) Generate(ctx context.Context, sys, user, model string) (string, *digest.Usage, string, error) {
	if f, err := g.d.IdeasImapFloor(g.acct); err == nil {
		g.seen = append(g.seen, f)
	}
	return g.stage1Gen.Generate(ctx, sys, user, model)
}

// #615 (C6 for IMAP): the history backfill's mailbox drain mines the chunk and
// never lowers the stored forward floor while it runs.
func TestBackfillImap_MinesWindowNeverLowersTheStoredFloor(t *testing.T) {
	d := newTestDB(t)
	now := time.Now()
	from, to := now.Add(-72*time.Hour), now.Add(-24*time.Hour)
	acct := seedImapMailbox(t, d)
	saved := float64(now.Add(-time.Hour).Unix())
	require.NoError(t, d.SetIdeasImapFloor(acct, saved))
	seedImapMessage(t, d, acct, 5, "Subj", "in window", from.Add(time.Hour))
	seedImapMessage(t, d, acct, 6, "Subj", "after window", to.Add(time.Hour))

	gen := &imapFloorWatchGen{d: d, acct: acct}
	_, complete, err := New(d, backfillCfg(), gen, testLogger()).BackfillImap(context.Background(), acct, from, to)
	require.NoError(t, err)
	require.True(t, complete)
	assert.True(t, gen.saw("in window"), "the window is mined")
	assert.False(t, gen.saw("after window"), "the drain stays inside the chunk")
	require.NotEmpty(t, gen.seen)
	for _, f := range gen.seen {
		assert.Equal(t, saved, f, "the stored floor stays put during the drain")
	}
	floor, err := d.IdeasImapFloor(acct)
	require.NoError(t, err)
	assert.Equal(t, saved, floor, "the floor ends at max(saved, reached)")
}

// #615: `ideas mine --from` (Pipeline.Backfill) drains IMAP mailboxes too,
// and raises — never lowers — their floor.
func TestBackfill_DrainsImapMailbox(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	now := time.Now()
	from, to := now.Add(-72*time.Hour), now.Add(-24*time.Hour)
	acct := seedImapMailbox(t, d)
	saved := float64(now.Add(-time.Hour).Unix())
	require.NoError(t, d.SetIdeasImapFloor(acct, saved))
	seedImapMessage(t, d, acct, 5, "Subj", "old idea mail", from.Add(time.Hour))

	cfg := testCfg() // ideas.enabled off: stage 1 only, no consolidator call
	gen := &stage1Gen{}
	_, err := New(d, cfg, gen, testLogger()).Backfill(context.Background(), from, to, nil)
	require.NoError(t, err)
	assert.True(t, gen.saw("old idea mail"))
	assert.True(t, strings.Contains(strings.Join(gen.prompts, ""), "("+imapTag(acct, 5)+")"))
	floor, err := d.IdeasImapFloor(acct)
	require.NoError(t, err)
	assert.Equal(t, saved, floor)
}
