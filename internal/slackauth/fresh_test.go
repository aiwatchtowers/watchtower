package slackauth

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/fsutil"
	"watchtower/internal/slack"
)

var t0 = time.Date(2026, 11, 18, 9, 0, 0, 0, time.UTC)

func clockAt(at time.Time) func() time.Time { return func() time.Time { return at } }

type fixture struct {
	dir string
	db  *db.DB
	id  int64
}

// newFixture makes one account row with clientID/appID and a workspace dir.
func newFixture(t *testing.T, clientID, appID string) fixture {
	t.Helper()
	database := db.OpenTestDB(t)
	id, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T0ACME", TeamName: "Acme", CurrentUserID: "U0OWNER"})
	require.NoError(t, err)
	if clientID != "" || appID != "" {
		require.NoError(t, database.SetSlackAccountApp(id, clientID, appID))
	}
	return fixture{dir: filepath.Join(t.TempDir(), "ws"), db: database, id: id}
}

func (f fixture) store() *slack.TokenStore { return slack.NewTokenStore(f.dir, f.id) }

func (f fixture) save(t *testing.T, tok *slack.Token) {
	t.Helper()
	require.NoError(t, f.store().Save(tok))
}

func (f fixture) row(t *testing.T) db.SlackAccount {
	t.Helper()
	r, err := f.db.GetSlackAccount(f.id)
	require.NoError(t, err)
	return r
}

func rotated(expires, refreshExpires time.Time) *slack.Token {
	return &slack.Token{
		AccessToken: "xoxe.xoxp-old", TeamID: "T0ACME", UserID: "U0OWNER",
		RefreshToken: "xoxe-1-old", ExpiresAt: expires, RefreshExpiresAt: refreshExpires,
		ClientID: "111.222",
	}
}

// fakeRefresher answers with a new token and counts its calls.
type fakeRefresher struct {
	mu    sync.Mutex
	calls int
	used  map[string]bool
}

func (f *fakeRefresher) refresh(_ context.Context, clientID, refreshToken string) (Refreshed, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	if f.used == nil {
		f.used = map[string]bool{}
	}
	if f.used[refreshToken] || clientID == "" {
		return Refreshed{}, &RefreshError{Code: codeInvalidRefreshToken}
	}
	f.used[refreshToken] = true
	return Refreshed{
		AccessToken: "xoxe.xoxp-new", RefreshToken: "xoxe-1-new",
		ExpiresIn: 43200, RefreshExpiresIn: 30 * 24 * 3600,
	}, nil
}

func (f *fakeRefresher) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

func mustNotRefresh(t *testing.T) Refresher {
	return func(context.Context, string, string) (Refreshed, error) {
		t.Error("refresher called")
		return Refreshed{}, errors.New("unexpected")
	}
}

func TestSlackRefresh_NoRotationUntouched(t *testing.T) {
	t.Parallel()
	f := newFixture(t, "111.222", "")
	f.save(t, &slack.Token{AccessToken: "xoxp-plain", TeamID: "T0ACME", ClientID: "111.222"})
	before, err := os.ReadFile(f.store().Path())
	require.NoError(t, err)

	tok, err := LoadFresh(context.Background(), f.dir, f.db, f.id, mustNotRefresh(t), clockAt(t0))
	require.NoError(t, err)
	require.NotNil(t, tok)
	assert.Equal(t, "xoxp-plain", tok.AccessToken)
	after, err := os.ReadFile(f.store().Path())
	require.NoError(t, err)
	assert.Equal(t, before, after)

	// A missing file is (nil, nil), as TokenStore.Load.
	g := newFixture(t, "", "")
	tok, err = LoadFresh(context.Background(), g.dir, g.db, g.id, mustNotRefresh(t), clockAt(t0))
	require.NoError(t, err)
	assert.Nil(t, tok)
}

func TestSlackRefresh_RefreshesWhenDue(t *testing.T) {
	t.Parallel()
	f := newFixture(t, "111.222", "")
	f.save(t, rotated(t0.Add(2*time.Hour), t0.Add(20*24*time.Hour)))
	r := &fakeRefresher{}

	// Two hours left: not due.
	tok, err := LoadFresh(context.Background(), f.dir, f.db, f.id, r.refresh, clockAt(t0))
	require.NoError(t, err)
	assert.Equal(t, "xoxe.xoxp-old", tok.AccessToken)
	assert.Zero(t, r.count())

	// 59 minutes left: due.
	now := t0.Add(time.Hour + time.Minute)
	tok, err = LoadFresh(context.Background(), f.dir, f.db, f.id, r.refresh, clockAt(now))
	require.NoError(t, err)
	assert.Equal(t, 1, r.count())
	assert.Equal(t, "xoxe.xoxp-new", tok.AccessToken)
	assert.Equal(t, "xoxe-1-new", tok.RefreshToken)
	assert.True(t, now.Add(12*time.Hour).Equal(tok.ExpiresAt))
	assert.True(t, now.Add(30*24*time.Hour).Equal(tok.RefreshExpiresAt))

	saved, err := f.store().Load()
	require.NoError(t, err)
	assert.Equal(t, "xoxe.xoxp-new", saved.AccessToken)
	assert.Equal(t, "xoxe-1-new", saved.RefreshToken)
	assert.Equal(t, "111.222", saved.ClientID)
	assert.Equal(t, now.Add(30*24*time.Hour).UTC().Format(time.RFC3339), f.row(t).RefreshTokenExpiresAt)

	// The fresh token is used as is on the next read.
	_, err = LoadFresh(context.Background(), f.dir, f.db, f.id, r.refresh, clockAt(now))
	require.NoError(t, err)
	assert.Equal(t, 1, r.count())
}

func TestSlackRefresh_RefreshTokenNearExpiry(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name      string
		left      time.Duration
		wantCalls int
	}{
		{"six days left refreshes", 6 * 24 * time.Hour, 1},
		{"eight days left waits", 8 * 24 * time.Hour, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t, "111.222", "")
			f.save(t, rotated(t0.Add(10*time.Hour), t0.Add(tc.left)))
			r := &fakeRefresher{}
			_, err := LoadFresh(context.Background(), f.dir, f.db, f.id, r.refresh, clockAt(t0))
			require.NoError(t, err)
			assert.Equal(t, tc.wantCalls, r.count())
		})
	}
}

// Two readers due at once: the one holding the lock refreshes, the other
// waits, re-reads the file and uses the new token — the old refresh token is
// never sent twice (the fake refuses a second use).
func TestSlackRefresh_LockRace(t *testing.T) {
	t.Parallel()
	f := newFixture(t, "111.222", "")
	f.save(t, rotated(t0.Add(10*time.Minute), t0.Add(20*24*time.Hour)))
	r := &fakeRefresher{}

	synctest.Test(t, func(t *testing.T) {
		var inRefresh atomic.Bool
		refresh := func(ctx context.Context, clientID, refreshToken string) (Refreshed, error) {
			if inRefresh.CompareAndSwap(false, true) {
				// The other reader is now parked on the lock.
				synctest.Wait()
			}
			return r.refresh(ctx, clientID, refreshToken)
		}
		var wg sync.WaitGroup
		got := make([]string, 2)
		errs := make([]error, 2)
		for i := range 2 {
			wg.Go(func() {
				tok, err := LoadFresh(context.Background(), f.dir, f.db, f.id, refresh, clockAt(t0))
				errs[i] = err
				if tok != nil {
					got[i] = tok.AccessToken
				}
			})
		}
		wg.Wait()
		require.NoError(t, errs[0])
		require.NoError(t, errs[1])
		assert.Equal(t, []string{"xoxe.xoxp-new", "xoxe.xoxp-new"}, got)
	})
	assert.Equal(t, 1, r.count())
	assert.Equal(t, "ok", f.row(t).Status)
}

// The lock is held across the refresh and the save.
func TestSlackRefresh_HoldsLockWhileRefreshing(t *testing.T) {
	t.Parallel()
	f := newFixture(t, "111.222", "")
	f.save(t, rotated(t0.Add(10*time.Minute), t0.Add(20*24*time.Hour)))
	r := &fakeRefresher{}
	refresh := func(ctx context.Context, clientID, refreshToken string) (Refreshed, error) {
		unlock, ok, err := tryLock(f.store())
		assert.NoError(t, err)
		if ok {
			unlock()
		}
		assert.False(t, ok, "the account's lock is held during the refresh")
		return r.refresh(ctx, clientID, refreshToken)
	}
	_, err := LoadFresh(context.Background(), f.dir, f.db, f.id, refresh, clockAt(t0))
	require.NoError(t, err)
	unlock, ok, err := tryLock(f.store())
	require.NoError(t, err)
	require.True(t, ok, "released after LoadFresh")
	unlock()
}

func TestSlackRefresh_Expired(t *testing.T) {
	t.Parallel()
	for _, code := range []string{codeInvalidRefreshToken, codeTokenRevoked} {
		t.Run(code, func(t *testing.T) {
			f := newFixture(t, "111.222", "")
			f.save(t, rotated(t0.Add(10*time.Minute), t0.Add(20*24*time.Hour)))
			refresh := func(context.Context, string, string) (Refreshed, error) {
				return Refreshed{}, &RefreshError{Code: code}
			}
			tok, err := LoadFresh(context.Background(), f.dir, f.db, f.id, refresh, clockAt(t0))
			require.ErrorIs(t, err, ErrReloginNeeded)
			assert.Nil(t, tok)
			row := f.row(t)
			assert.Equal(t, "error", row.Status)
			assert.Equal(t, "Sign in again: the Slack sign-in expired", row.Error)
			saved, err := f.store().Load()
			require.NoError(t, err)
			assert.Equal(t, "xoxe-1-old", saved.RefreshToken, "the file is left as it was")
		})
	}

	// Any other failure is no Re-login: the row stays ok.
	f := newFixture(t, "111.222", "")
	f.save(t, rotated(t0.Add(10*time.Minute), t0.Add(20*24*time.Hour)))
	refresh := func(context.Context, string, string) (Refreshed, error) {
		return Refreshed{}, &RefreshError{Code: "ratelimited"}
	}
	_, err := LoadFresh(context.Background(), f.dir, f.db, f.id, refresh, clockAt(t0))
	require.Error(t, err)
	assert.NotErrorIs(t, err, ErrReloginNeeded)
	assert.Equal(t, "ok", f.row(t).Status)
}

func TestSlackRefresh_NoSecretInForm(t *testing.T) {
	t.Parallel()
	var form map[string][]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, http.MethodPost, r.Method)
		assert.NoError(t, r.ParseForm())
		form = r.PostForm
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true,"access_token":"xoxe.xoxp-new","refresh_token":"xoxe-1-new",` +
			`"expires_in":43200,"` + refreshExpiryField + `":2592000,"token_type":"user"}`))
	}))
	t.Cleanup(srv.Close)

	got, err := NewRefresher(srv.Client(), srv.URL)(context.Background(), "111.222", "xoxe-1-old")
	require.NoError(t, err)
	assert.Equal(t, map[string][]string{
		"grant_type":    {"refresh_token"},
		"client_id":     {"111.222"},
		"refresh_token": {"xoxe-1-old"},
	}, form, "client_id and refresh_token only: no client secret")
	assert.Equal(t, Refreshed{AccessToken: "xoxe.xoxp-new", RefreshToken: "xoxe-1-new", ExpiresIn: 43200, RefreshExpiresIn: 2592000}, got)
}

func TestSlackRefresh_DecodesUserAndErrors(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, body string
		want       Refreshed
		relogin    bool
		wantErr    bool
	}{
		{
			name: "authed_user",
			body: `{"ok":true,"authed_user":{"access_token":"xoxe.xoxp-u","refresh_token":"r2","expires_in":60}}`,
			want: Refreshed{AccessToken: "xoxe.xoxp-u", RefreshToken: "r2", ExpiresIn: 60},
		},
		{name: "invalid", body: `{"ok":false,"error":"invalid_refresh_token"}`, wantErr: true, relogin: true},
		{name: "revoked", body: `{"ok":false,"error":"token_revoked"}`, wantErr: true, relogin: true},
		{name: "other", body: `{"ok":false,"error":"invalid_client_id"}`, wantErr: true},
		{name: "no token", body: `{"ok":true}`, wantErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				_, _ = w.Write([]byte(tc.body))
			}))
			t.Cleanup(srv.Close)
			got, err := NewRefresher(srv.Client(), srv.URL)(context.Background(), "111.222", "r1")
			if tc.wantErr {
				require.Error(t, err)
				assert.Equal(t, tc.relogin, IsReloginError(err))
				return
			}
			require.NoError(t, err)
			assert.Equal(t, tc.want, got)
		})
	}
}

// A redirect is never followed: it would replay the refresh token.
func TestSlackRefresh_RefusesRedirect(t *testing.T) {
	t.Parallel()
	var hits atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { hits.Add(1) }))
	t.Cleanup(target.Close)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL, http.StatusTemporaryRedirect)
	}))
	t.Cleanup(srv.Close)
	_, err := NewRefresher(srv.Client(), srv.URL)(context.Background(), "111.222", "r1")
	require.Error(t, err)
	assert.Zero(t, hits.Load())
}

func TestSlackRefresh_CrashBeforeSaveKeepsOldFile(t *testing.T) {
	t.Parallel()
	f := newFixture(t, "111.222", "")
	f.save(t, rotated(t0.Add(10*time.Minute), t0.Add(20*24*time.Hour)))
	before, err := os.ReadFile(f.store().Path())
	require.NoError(t, err)
	// The lock file exists; then the dir refuses new files, so the atomic
	// save cannot create its temp file.
	unlock, err := f.store().Lock(context.Background())
	require.NoError(t, err)
	unlock()
	require.NoError(t, os.Chmod(f.dir, 0o500))
	t.Cleanup(func() { _ = os.Chmod(f.dir, 0o700) })

	r := &fakeRefresher{}
	tok, err := LoadFresh(context.Background(), f.dir, f.db, f.id, r.refresh, clockAt(t0))
	require.Error(t, err)
	assert.Nil(t, tok)
	assert.Equal(t, 1, r.count())
	after, err := os.ReadFile(f.store().Path())
	require.NoError(t, err)
	assert.Equal(t, before, after, "the old file is intact")
	assert.Empty(t, f.row(t).RefreshTokenExpiresAt, "the row is not touched")
}

func TestSlackRefresh_RepairsRowFromFile(t *testing.T) {
	t.Parallel()
	// The file names a new app (a connect crashed after the token save).
	f := newFixture(t, "999.000", "A0OLD")
	f.save(t, &slack.Token{AccessToken: "xoxp-a", TeamID: "T0ACME", ClientID: "111.222", AppID: "A0NEW"})
	_, err := LoadFresh(context.Background(), f.dir, f.db, f.id, mustNotRefresh(t), clockAt(t0))
	require.NoError(t, err)
	row := f.row(t)
	assert.Equal(t, "111.222", row.ClientID)
	assert.Equal(t, "A0NEW", row.AppID)

	// A new client id without an App ID clears the old app's id.
	g := newFixture(t, "999.000", "A0OLD")
	g.save(t, &slack.Token{AccessToken: "xoxp-a", TeamID: "T0ACME", ClientID: "111.222"})
	_, err = LoadFresh(context.Background(), g.dir, g.db, g.id, mustNotRefresh(t), clockAt(t0))
	require.NoError(t, err)
	row = g.row(t)
	assert.Equal(t, "111.222", row.ClientID)
	assert.Empty(t, row.AppID)

	// Same client id, the App ID learned later.
	h := newFixture(t, "111.222", "")
	h.save(t, &slack.Token{AccessToken: "xoxp-a", TeamID: "T0ACME", ClientID: "111.222", AppID: "A0NEW"})
	_, err = LoadFresh(context.Background(), h.dir, h.db, h.id, mustNotRefresh(t), clockAt(t0))
	require.NoError(t, err)
	assert.Equal(t, "A0NEW", h.row(t).AppID)
}

// Files written before client and app ids were recorded — and a file
// rewritten without them — never blank the row's backfilled client id.
func TestSlackRefresh_LegacyTokenFileNeverBlanksRow(t *testing.T) {
	t.Parallel()
	t.Run("old file", func(t *testing.T) {
		f := newFixture(t, "111.222", "A0APP")
		f.save(t, &slack.Token{AccessToken: "xoxp-old", TeamID: "T0ACME", UserID: "U0OWNER"})
		for range 2 {
			_, err := LoadFresh(context.Background(), f.dir, f.db, f.id, mustNotRefresh(t), clockAt(t0))
			require.NoError(t, err)
			row := f.row(t)
			assert.Equal(t, "111.222", row.ClientID)
			assert.Equal(t, "A0APP", row.AppID)
		}
	})
	t.Run("rewritten rotating file without client id", func(t *testing.T) {
		f := newFixture(t, "111.222", "A0APP")
		tok := rotated(t0.Add(10*time.Minute), t0.Add(20*24*time.Hour))
		tok.ClientID = ""
		f.save(t, tok)
		r := &fakeRefresher{}
		for range 2 {
			got, err := LoadFresh(context.Background(), f.dir, f.db, f.id, r.refresh, clockAt(t0))
			require.NoError(t, err)
			assert.Equal(t, "xoxe.xoxp-new", got.AccessToken, "refreshed with the row's client id")
			row := f.row(t)
			assert.Equal(t, "111.222", row.ClientID)
			assert.Equal(t, "A0APP", row.AppID)
		}
		assert.Equal(t, 1, r.count())
	})
	t.Run("file with an app id but no client id", func(t *testing.T) {
		f := newFixture(t, "111.222", "A0APP")
		f.save(t, &slack.Token{AccessToken: "xoxp-old", TeamID: "T0ACME", AppID: "A0OTHER"})
		_, err := LoadFresh(context.Background(), f.dir, f.db, f.id, mustNotRefresh(t), clockAt(t0))
		require.NoError(t, err)
		row := f.row(t)
		assert.Equal(t, "111.222", row.ClientID)
		assert.Equal(t, "A0APP", row.AppID)
	})
}

// tryLock takes the account's flock without waiting.
func tryLock(s *slack.TokenStore) (func(), bool, error) {
	return fsutil.TryLockFile(s.Path() + ".lock")
}

// A cancel of the caller after Slack rotated the token must not lose the
// answer: the refresh and the save run on a context the caller cannot cancel.
func TestSlackRefresh_CallerCancelStillSaves(t *testing.T) {
	t.Parallel()
	f := newFixture(t, "111.222", "")
	f.save(t, rotated(t0.Add(10*time.Minute), t0.Add(20*24*time.Hour)))
	r := &fakeRefresher{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	refresh := func(rctx context.Context, clientID, refreshToken string) (Refreshed, error) {
		cancel() // Sync Now pressed again, the Mac sleeps, Ctrl-C …
		assert.NoError(t, rctx.Err(), "the refresh's own context survives the caller's cancel")
		_, hasDeadline := rctx.Deadline()
		assert.True(t, hasDeadline, "bounded by refreshTimeout")
		return r.refresh(rctx, clientID, refreshToken)
	}
	tok, err := LoadFresh(ctx, f.dir, f.db, f.id, refresh, clockAt(t0))
	require.NoError(t, err)
	assert.Equal(t, "xoxe.xoxp-new", tok.AccessToken)
	saved, err := f.store().Load()
	require.NoError(t, err)
	assert.Equal(t, "xoxe-1-new", saved.RefreshToken, "the rotated refresh token is on disk")
}

// Expiries Slack's answer does not state: a new refresh token gets the
// 30-day default, an unrotated one keeps its expiry, and a missing
// expires_in keeps the access token's.
func TestSlackRefresh_UnstatedExpiries(t *testing.T) {
	t.Parallel()
	oldAccess := t0.Add(10 * time.Minute)
	oldRefresh := t0.Add(5 * 24 * time.Hour)
	for _, tc := range []struct {
		name                    string
		got                     Refreshed
		wantAccess, wantRefresh time.Time
		wantRefreshToken        string
	}{
		{
			name:       "rotated without a lifetime",
			got:        Refreshed{AccessToken: "a2", RefreshToken: "r2", ExpiresIn: 43200},
			wantAccess: t0.Add(12 * time.Hour), wantRefresh: t0.Add(30 * 24 * time.Hour), wantRefreshToken: "r2",
		},
		{
			name:       "same refresh token",
			got:        Refreshed{AccessToken: "a2", RefreshToken: "xoxe-1-old", ExpiresIn: 43200},
			wantAccess: t0.Add(12 * time.Hour), wantRefresh: oldRefresh, wantRefreshToken: "xoxe-1-old",
		},
		{
			name:       "no refresh token in the answer",
			got:        Refreshed{AccessToken: "a2", ExpiresIn: 43200},
			wantAccess: t0.Add(12 * time.Hour), wantRefresh: oldRefresh, wantRefreshToken: "xoxe-1-old",
		},
		{
			name:       "no expires_in",
			got:        Refreshed{AccessToken: "a2", RefreshToken: "r2", RefreshExpiresIn: 3600},
			wantAccess: oldAccess, wantRefresh: t0.Add(time.Hour), wantRefreshToken: "r2",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t, "111.222", "")
			f.save(t, rotated(oldAccess, oldRefresh))
			refresh := func(context.Context, string, string) (Refreshed, error) { return tc.got, nil }
			tok, err := LoadFresh(context.Background(), f.dir, f.db, f.id, refresh, clockAt(t0))
			require.NoError(t, err)
			assert.True(t, tc.wantAccess.Equal(tok.ExpiresAt), "access expiry %v", tok.ExpiresAt)
			assert.True(t, tc.wantRefresh.Equal(tok.RefreshExpiresAt), "refresh expiry %v", tok.RefreshExpiresAt)
			assert.Equal(t, tc.wantRefreshToken, tok.RefreshToken)
			assert.Equal(t, tc.wantRefresh.UTC().Format(time.RFC3339), f.row(t).RefreshTokenExpiresAt, "the column is never blanked")
		})
	}
}

// A save that fails once after a successful refresh is tried again under the
// lock. Not parallel: it sets the saveFault seam.
func TestSlackRefresh_SaveRetriedOnce(t *testing.T) {
	f := newFixture(t, "111.222", "")
	f.save(t, rotated(t0.Add(10*time.Minute), t0.Add(20*24*time.Hour)))
	t.Cleanup(func() { saveFault = nil })
	attempts := 0
	saveFault = func() error {
		attempts++
		if attempts == 1 {
			return errors.New("disk hiccup")
		}
		return nil
	}
	r := &fakeRefresher{}
	tok, err := LoadFresh(context.Background(), f.dir, f.db, f.id, r.refresh, clockAt(t0))
	require.NoError(t, err)
	assert.Equal(t, 2, attempts)
	assert.Equal(t, "xoxe.xoxp-new", tok.AccessToken)
	saved, err := f.store().Load()
	require.NoError(t, err)
	assert.Equal(t, "xoxe-1-new", saved.RefreshToken)
}

// The row's expiry column failing after the file is saved does not fail the
// read: the file is the source of truth.
func TestSlackRefresh_RowExpiryFailureStillReturnsToken(t *testing.T) {
	t.Parallel()
	f := newFixture(t, "111.222", "")
	f.save(t, rotated(t0.Add(10*time.Minute), t0.Add(20*24*time.Hour)))
	r := &fakeRefresher{}
	refresh := func(ctx context.Context, clientID, refreshToken string) (Refreshed, error) {
		_, err := f.db.Exec(`DELETE FROM slack_accounts WHERE id = ?`, f.id)
		require.NoError(t, err)
		return r.refresh(ctx, clientID, refreshToken)
	}
	tok, err := LoadFresh(context.Background(), f.dir, f.db, f.id, refresh, clockAt(t0))
	require.NoError(t, err)
	assert.Equal(t, "xoxe.xoxp-new", tok.AccessToken)
	saved, err := f.store().Load()
	require.NoError(t, err)
	assert.Equal(t, "xoxe.xoxp-new", saved.AccessToken)
}
