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
	"watchtower/internal/prompts"
)

// seedImapMailbox inserts an IMAP email_accounts row and returns its id.
func seedImapMailbox(t *testing.T, d *db.DB) int64 {
	t.Helper()
	id, err := d.CreateEmailAccount(db.EmailAccount{Provider: "imap", EmailAddress: "me@example.com",
		Host: "imap.example.com", Port: 993, Security: "ssl", Folder: "INBOX"})
	require.NoError(t, err)
	require.NoError(t, d.SetImapWatermark(id, 0, 1)) // current UIDVALIDITY epoch 1
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
	require.NoError(t, New(d, testCfg(), gen, testLogger()).runEmailDigests(context.Background()))
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
	require.NoError(t, New(d, testCfg(), gen, testLogger()).runEmailDigests(context.Background()))
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
	proposed, _, err := New(d, testCfg(), gen, testLogger()).runConsolidate(context.Background())
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

// sysGen answers stage-1 calls with one idea citing the first ref tag in the
// prompt and records each call's system prompt.
type sysGen struct {
	systems []string
	users   []string
}

func (g *sysGen) Generate(_ context.Context, system, user, _ string) (string, *digest.Usage, string, error) {
	g.systems = append(g.systems, system)
	g.users = append(g.users, user)
	ref := ""
	if i := strings.Index(user, " ("); i >= 0 {
		if j := strings.Index(user[i:], "):"); j > 0 {
			ref = user[i+2 : i+j]
		}
	}
	return fmt.Sprintf(`{"topics":[{"title":"t","summary":"s","ideas":[{"text":"x","author":"Ann","ref":%q}],"decisions":[]}]}`, ref),
		&digest.Usage{}, "", nil
}

// #615 (F1/F4): a Google account and an IMAP mailbox sharing id 1 stay apart —
// own floors, own stream_digests rows (source + scope) and own refs.
func TestRunEmailDigests_GmailAndImapSameIDKeptApart(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Truncate(time.Second)
	g := seedGoogleAccount(t, d, float64(base.Unix()))
	m := seedImapMailbox(t, d)
	require.Equal(t, g, m, "the fixture needs the same id on both tables")
	setIdeasEmailFloorRaw(t, d, g, float64(base.Unix()))
	require.NoError(t, d.SetIdeasImapFloor(m, float64(base.Unix())))
	seedGmailMessageIdeas(t, d, g, "m1", "thr-1", "a@example.com", "Ann", "Subj", "gmail body",
		base.Add(10*time.Second).UTC().Format(time.RFC3339))
	seedImapMessage(t, d, m, 3, "Subj", "imap body", base.Add(30*time.Second))

	gen := &sysGen{}
	require.NoError(t, New(d, testCfg(), gen, testLogger()).runEmailDigests(context.Background()))
	require.Len(t, gen.users, 2)

	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	require.Len(t, digests, 2)
	bySource := map[string]db.StreamDigest{}
	for _, sd := range digests {
		bySource[sd.Source] = sd
	}
	assert.Contains(t, bySource["gmail"].TopicsJSON, fmt.Sprintf("gmail:%d:thr-1", g))
	assert.Empty(t, bySource["gmail"].Scope)
	assert.Contains(t, bySource["imap"].TopicsJSON, imapTag(m, 3))
	assert.Equal(t, "me@example.com", bySource["imap"].Scope, "an IMAP digest is scoped to its address")

	gf, err := d.IdeasEmailFloor(g)
	require.NoError(t, err)
	mf, err := d.IdeasImapFloor(m)
	require.NoError(t, err)
	assert.Equal(t, float64(base.Add(10*time.Second).Unix()), gf)
	assert.Equal(t, float64(base.Add(30*time.Second).Unix()), mf)
}

// #615 (F1): the same inbox connected as Gmail and over IMAP is mined once —
// the IMAP mailbox is skipped on the forward run and by the history backfill.
func TestRunEmailDigests_ImapDuplicateOfGmailSkipped(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour).Truncate(time.Second)
	_, err := d.Exec(`INSERT INTO google_accounts (email, label, gmail_enabled, gmail_last_internal_date, ideas_email_floor)
		VALUES ('Me@Example.com', 'Test', 1, ?, ?)`, float64(base.Unix()), float64(base.Unix()))
	require.NoError(t, err)
	m := seedImapMailbox(t, d) // me@example.com
	require.NoError(t, d.SetIdeasImapFloor(m, float64(base.Unix())))
	seedImapMessage(t, d, m, 3, "Subj", "imap body", base.Add(30*time.Second))

	gen := &sysGen{}
	p := New(d, testCfg(), gen, testLogger())
	require.NoError(t, p.runEmailDigests(context.Background()))
	_, complete, err := p.BackfillImap(context.Background(), m, base.Add(-48*time.Hour), base.Add(time.Hour))
	require.NoError(t, err)
	assert.True(t, complete)
	assert.Empty(t, gen.users, "a duplicate mailbox costs no AI call")
	mf, err := d.IdeasImapFloor(m)
	require.NoError(t, err)
	assert.Equal(t, float64(base.Unix()), mf)
}

// #615 (F6): a customized ideas.digest_email written when only gmail: tags
// existed gets the IMAP ref instruction appended, so an IMAP mailbox is not
// silently mined into nothing; the shipped v3 template needs no note.
func TestMineStreamTopics_OldTemplateGetsImapRefNote(t *testing.T) {
	for _, tc := range []struct {
		name     string
		template string
		wantNote bool
	}{
		{"customized pre-v3", "%s\nCopy the gmail:<account_id>:<thread_id> tag as the ref.", true},
		{"shipped default", prompts.Defaults[prompts.IdeasDigestEmail], false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d := newTestDB(t)
			require.NoError(t, d.UpsertPrompt(db.Prompt{ID: prompts.IdeasDigestEmail, Template: tc.template, Version: 2}))
			base := time.Now().Add(-time.Hour).Truncate(time.Second)
			m := seedImapMailbox(t, d)
			require.NoError(t, d.SetIdeasImapFloor(m, float64(base.Unix())))
			seedImapMessage(t, d, m, 3, "Subj", "imap body", base.Add(30*time.Second))

			gen := &sysGen{}
			p := New(d, testCfg(), gen, testLogger())
			p.SetPromptStore(prompts.New(d, nil))
			require.NoError(t, p.runEmailDigests(context.Background()))
			require.Len(t, gen.systems, 1)
			assert.Equal(t, tc.wantNote, strings.Contains(gen.systems[0], `start with "imap:"`))
		})
	}
}
