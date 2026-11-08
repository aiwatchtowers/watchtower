package ideas

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"testing"
	"time"
	"watchtower/internal/db"
	"watchtower/internal/digest"

	"github.com/stretchr/testify/require"
)

type providerWait struct{}

func (providerWait) Error() string          { return "provider waiting" }
func (providerWait) ProviderDeferred() bool { return true }

type routedStage1 struct {
	fakeGen
	waiting bool
}

func (g *routedStage1) RoutingPreflight(context.Context) error {
	if g.waiting {
		return providerWait{}
	}
	return nil
}

func TestStage1ProviderWaitBeforeCall(t *testing.T) {
	d := newTestDB(t)
	a := seedGoogleAccount(t, d, 10000)
	setIdeasEmailFloorRaw(t, d, a, 100)
	seedGmailMessageIdeas(t, d, a, "m1", "t1", "a@example.com", "A", "subject", "body", time.Unix(200, 0).UTC().Format(time.RFC3339))
	g := &routedStage1{waiting: true}
	g.reply = func(string) (string, error) { return `{"topics":[]}`, nil }
	p := New(d, testCfg(), g, testLogger())
	err := p.runEmailDigests(context.Background())
	require.True(t, digest.ProviderDeferred(err), "%v", err)
	require.Zero(t, g.calls)
	floor, e := d.IdeasEmailFloor(a)
	require.NoError(t, e)
	require.Equal(t, float64(100), floor)
	g.waiting = false
	require.NoError(t, p.runEmailDigests(context.Background()))
	require.Equal(t, 1, g.calls)
}
func TestStage1PassesPreserveMixedFailure(t *testing.T) {
	d := newTestDB(t)
	a := seedGoogleAccount(t, d, 10000)
	b := seedGoogleAccount(t, d, 10000)
	for _, id := range []int64{a, b} {
		setIdeasEmailFloorRaw(t, d, id, 100)
		seedGmailMessageIdeas(t, d, id, "m1", "t1", "a@example.com", "A", "subject", "body", time.Unix(200, 0).UTC().Format(time.RFC3339))
	}
	material := errors.New("invalid material")
	g := &routedStage1{}
	g.reply = func(string) (string, error) {
		if g.calls == 1 {
			return "", providerWait{}
		}
		return "", material
	}
	p := New(d, testCfg(), g, testLogger())
	err := p.runEmailDigests(context.Background())
	require.ErrorIs(t, err, material)
	require.False(t, digest.ProviderDeferred(err))
}

// Reconstructing the pipeline models a daemon restart with no in-memory resume
// map. Even a valid empty extraction is a committed prefix of this exact drain.
func TestBackfillProviderDeferredRestartMissingOnly(t *testing.T) {
	for _, source := range []string{"gmail", "jira", "imap"} {
		for _, empty := range []bool{true, false} {
			t.Run(fmt.Sprintf("%s/empty=%t", source, empty), func(t *testing.T) {
				path := filepath.Join(t.TempDir(), "watchtower.db")
				d, err := db.Open(path)
				require.NoError(t, err)
				t.Cleanup(func() { require.NoError(t, d.Close()) })
				from := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
				to := from.Add(72 * time.Hour)
				cfg := testCfgWithBudget(1)
				var acct int64
				switch source {
				case "gmail":
					acct = seedGoogleAccount(t, d, float64(to.Add(time.Hour).Unix()))
					setIdeasEmailFloorRaw(t, d, acct, float64(from.Add(-time.Hour).Unix()))
				case "jira":
					acct = seedJiraAccount(t, d)
					setIdeasJiraFloorRaw(t, d, acct, db.FormatJiraTime(from.Add(-time.Hour)))
				case "imap":
					res, err := d.Exec(`INSERT INTO email_accounts(provider,email_address,host,port) VALUES('imap','imap@example.com','imap.example.com',993)`)
					require.NoError(t, err)
					acct, err = res.LastInsertId()
					require.NoError(t, err)
					_, err = d.Exec(`UPDATE email_accounts SET ideas_email_floor=? WHERE id=?`, from.Add(-time.Hour).Unix(), acct)
					require.NoError(t, err)
				}
				for i := 1; i <= 2; i++ {
					at := from.Add(time.Duration(i) * time.Hour)
					if source == "jira" {
						at = at.Add(123 * time.Millisecond)
					}
					switch source {
					case "gmail":
						seedGmailMessageIdeas(t, d, acct, fmt.Sprintf("m%d", i), fmt.Sprintf("t%d", i), "a@example.com", "A", "subject", "body", at.Format(time.RFC3339))
					case "jira":
						seedJiraIssueIdeas(t, d, acct, fmt.Sprintf("WT-%d", i), "WT", "issue", "Open", "new", "body", db.FormatJiraTime(at))
					case "imap":
						_, err := d.Exec(`INSERT INTO imap_messages(account_id,uid,subject,from_email,body_text,internal_date,synced_at) VALUES(?,?,'subject','a@example.com','body',?,?)`, acct, i, at.Format(time.RFC3339), at.Format(time.RFC3339))
						require.NoError(t, err)
					}
				}
				g := &routedStage1{}
				g.reply = func(user string) (string, error) {
					if g.calls == 2 {
						return "", providerWait{}
					}
					if empty {
						return `{"topics":[]}`, nil
					}
					ref := fmt.Sprintf("gmail:%d:t1", acct)
					if source == "jira" {
						ref = "WT-1"
					}
					if source == "imap" {
						ref = fmt.Sprintf("imap:%d:0-1", acct)
					}
					return fmt.Sprintf(`{"topics":[{"title":"topic","summary":"summary","ideas":[{"text":"idea","author":"A","ref":%q}],"decisions":[]}]}`, ref), nil
				}
				run := func(p *Pipeline) (time.Time, bool, error) {
					switch source {
					case "gmail":
						return p.BackfillEmail(context.Background(), acct, from, to)
					case "imap":
						return p.BackfillImap(context.Background(), acct, from, to)
					default:
						return p.BackfillJira(context.Background(), acct, from, to)
					}
				}
				p := New(d, cfg, g, testLogger())
				g.waiting = true
				_, complete, err := run(p)
				require.True(t, digest.ProviderDeferred(err))
				require.False(t, complete)
				require.Zero(t, g.calls)
				g.waiting = false
				reached, complete, err := run(p)
				require.True(t, digest.ProviderDeferred(err), "%v", err)
				require.False(t, complete)
				expected := from.Add(time.Hour)
				if source == "jira" {
					expected = expected.Add(123 * time.Millisecond)
				}
				require.True(t, reached.Equal(expected), "%v != %v", reached, expected)
				var receipts int
				require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM ideas_extraction_windows WHERE complete=1`).Scan(&receipts))
				require.Equal(t, 1, receipts)
				prior, err := d.ListStreamDigestsAfter(0, "")
				require.NoError(t, err)
				if !empty {
					require.Len(t, prior, 1)
				}
				require.NoError(t, d.Close())
				d, err = db.Open(path)
				require.NoError(t, err)
				g.reply = func(user string) (string, error) {
					require.NotContains(t, user, fmt.Sprintf("(gmail:%d:t1)", acct))
					require.NotContains(t, user, "(WT-1)")
					require.NotContains(t, user, fmt.Sprintf("(imap:%d:0-1)", acct))
					return `{"topics":[]}`, nil
				}
				_, complete, err = run(New(d, cfg, g, testLogger()))
				require.NoError(t, err)
				require.True(t, complete)
				require.Equal(t, 3, g.calls)
				after, err := d.ListStreamDigestsAfter(0, "")
				require.NoError(t, err)
				require.Len(t, after, len(prior))
				_, complete, err = run(New(d, cfg, g, testLogger()))
				require.NoError(t, err)
				require.True(t, complete)
				require.Equal(t, 3, g.calls, "completed chunk receipt survives missing runner acknowledgement")
			})
		}
	}
}

func TestForwardDeferredKeepsClaimedUpperBound(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().UTC().Truncate(time.Second).Add(-24 * time.Hour)
	a := seedGoogleAccount(t, d, float64(time.Now().Unix()))
	setIdeasEmailFloorRaw(t, d, a, float64(base.Unix()))
	for i := 1; i <= 2; i++ {
		seedGmailMessageIdeas(t, d, a, fmt.Sprintf("m%d", i), fmt.Sprintf("t%d", i), "a@example.com", "A", "subject", fmt.Sprintf("mail-%d", i), base.Add(time.Duration(i)*time.Hour).Format(time.RFC3339))
	}
	g := &routedStage1{waiting: true}
	g.reply = func(user string) (string, error) {
		require.Contains(t, user, "mail-1")
		require.NotContains(t, user, "mail-2")
		return `{"topics":[]}`, nil
	}
	p := New(d, testCfg(), g, testLogger())
	require.True(t, digest.ProviderDeferred(p.runEmailDigests(context.Background())))
	require.Zero(t, g.calls)
	// Represent the original claim made before newer input arrived; a retry must
	// use persisted metadata, rather than rebuilding its upper bound from now.
	_, err := d.Exec(`UPDATE ideas_extraction_windows SET to_value=? WHERE window_key='forward'`, base.Add(90*time.Minute).Format(time.RFC3339Nano))
	require.NoError(t, err)
	g.waiting = false
	require.NoError(t, New(d, testCfg(), g, testLogger()).runEmailDigests(context.Background()))
	require.Equal(t, 1, g.calls)
	floor, err := d.IdeasEmailFloor(a)
	require.NoError(t, err)
	require.Equal(t, float64(base.Add(time.Hour).Unix()), floor)
}

// The production account wrapper must not undo its transaction's monotonic
// floor when a retained forward claim completes below newer historical work.
func TestForwardAccountWrapperRetainsHigherHistoricalFloor(t *testing.T) {
	for _, source := range []string{"gmail", "imap", "jira"} {
		for _, empty := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/empty=%t", source, empty), func(t *testing.T) {
				d := newTestDB(t)
				base := time.Now().UTC().Add(-24 * time.Hour).Truncate(time.Second)
				bound := base.Add(90 * time.Minute)
				higher := base.Add(2 * time.Hour)
				older := base.Add(time.Hour)
				var account int64
				switch source {
				case "gmail":
					account = seedGoogleAccount(t, d, float64(time.Now().Unix()))
					setIdeasEmailFloorRaw(t, d, account, float64(base.Unix()))
				case "imap":
					res, err := d.Exec(`INSERT INTO email_accounts(provider,email_address) VALUES('imap','imap@example.com')`)
					require.NoError(t, err)
					account, err = res.LastInsertId()
					require.NoError(t, err)
				case "jira":
					account = seedJiraAccount(t, d)
					older = older.Add(123 * time.Millisecond)
					higher = higher.Add(456 * time.Millisecond)
				}
				floor := fmt.Sprint(base.Unix())
				if source == "jira" {
					floor = db.FormatJiraTime(base)
				}
				_, err := d.ClaimIdeasExtractionWindow(db.IdeasExtractionWindow{Source: source, AccountID: account, Key: "forward", From: floor, To: bound.Format(time.RFC3339Nano)})
				require.NoError(t, err)
				// Historical extraction committed after the forward input claim was retained.
				switch source {
				case "gmail":
					setIdeasEmailFloorRaw(t, d, account, float64(higher.Unix()))
				case "imap":
					_, err = d.Exec(`UPDATE email_accounts SET ideas_email_floor=? WHERE id=?`, higher.Unix(), account)
					require.NoError(t, err)
				case "jira":
					setIdeasJiraFloorRaw(t, d, account, db.FormatJiraTime(higher))
				}
				if !empty {
					switch source {
					case "gmail":
						seedGmailMessageIdeas(t, d, account, "m1", "t1", "a@example.com", "A", "subject", "older pending input", older.Format(time.RFC3339))
					case "imap":
						_, err = d.Exec(`INSERT INTO imap_messages(account_id,uid,body_text,internal_date) VALUES(?,1,'older pending input',?)`, account, older.Format(time.RFC3339))
						require.NoError(t, err)
					case "jira":
						seedJiraIssueIdeas(t, d, account, "WT-1", "WT", "older pending input", "Open", "new", "body", db.FormatJiraTime(older))
					}
				}
				// This later input is already covered by the higher historical floor and
				// lies outside the retained forward claim. The following cycle must exclude it.
				switch source {
				case "gmail":
					seedGmailMessageIdeas(t, d, account, "m2", "t2", "a@example.com", "A", "subject", "already completed historical input", higher.Format(time.RFC3339))
				case "imap":
					_, err = d.Exec(`INSERT INTO imap_messages(account_id,uid,body_text,internal_date) VALUES(?,2,'already completed historical input',?)`, account, higher.Format(time.RFC3339))
					require.NoError(t, err)
				case "jira":
					seedJiraIssueIdeas(t, d, account, "WT-2", "WT", "already completed historical input", "Open", "new", "body", db.FormatJiraTime(higher))
				}
				g := &routedStage1{}
				g.reply = func(string) (string, error) { return `{"topics":[]}`, nil }
				run := func() error {
					p := New(d, testCfg(), g, testLogger())
					if source == "jira" {
						acct, e := d.GetJiraAccount(account)
						require.NoError(t, e)
						return p.runJiraDigestAccount(context.Background(), acct, time.Time{})
					}
					mb := gmailBox(account)
					if source == "imap" {
						mb = imapBox(account)
					}
					return p.runEmailDigestAccount(context.Background(), mb, time.Time{})
				}
				require.NoError(t, run())
				if source == "jira" {
					got, e := d.IdeasJiraFloor(account)
					require.NoError(t, e)
					require.Equal(t, db.FormatJiraTime(higher), got)
				} else {
					mb := gmailBox(account)
					if source == "imap" {
						mb = imapBox(account)
					}
					got, e := New(d, testCfg(), g, testLogger()).mailFloor(mb)
					require.NoError(t, e)
					require.Equal(t, float64(higher.Unix()), got)
				}
				calls := g.calls
				require.NoError(t, run())
				require.Equal(t, calls, g.calls, "next forward cycle must not mine already-completed historical input")
			})
		}
	}
}
