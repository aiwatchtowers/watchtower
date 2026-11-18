package cmd

import (
	"bytes"
	"context"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/fsutil"
	watchtowerslack "watchtower/internal/slack"
	"watchtower/internal/slackauth"
)

// The legacy config-token migration saves the token file under the account's
// token lock (review #1426): while another process holds it the migration
// waits, and once it is released the file is written.
func TestEnsureLegacySlackAccount_SavesUnderLock(t *testing.T) {
	// Identity resolution fails before any connection is made (a URL with no
	// scheme), so the run stays offline inside the bubble.
	original := newSlackClientForToken
	newSlackClientForToken = func(token string) *watchtowerslack.Client {
		return watchtowerslack.NewClientWithAPIURLUnlimited(token, "://offline/")
	}
	t.Cleanup(func() { newSlackClientForToken = original })
	t.Setenv("HOME", t.TempDir())
	writeLegacyConfig(t, "xoxp-legacy-token")
	cfg := &config.Config{
		ActiveWorkspace: "test",
		Workspaces:      map[string]*config.WorkspaceConfig{"test": {SlackToken: "xoxp-legacy-token"}},
	}
	database := db.OpenTestDB(t)
	id, err := database.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)
	store := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), id)
	unlock, err := store.Lock(context.Background())
	require.NoError(t, err)

	synctest.Test(t, func(t *testing.T) {
		done := make(chan error, 1)
		go func() {
			_, err := ensureLegacySlackAccount(context.Background(), cfg, database, quietTestLogger())
			done <- err
		}()
		synctest.Wait() // the migration is parked on the lock
		assert.False(t, store.Exists(), "nothing is written while another process holds the lock")
		unlock()
		require.NoError(t, <-done)
	})
	tok, err := store.Load()
	require.NoError(t, err)
	require.NotNil(t, tok)
	assert.Equal(t, "xoxp-legacy-token", tok.AccessToken)
}

// slackTokenWriters is every function allowed to write or delete a Slack
// token file (slack_token_<id>.json), each under TokenStore.Lock (plan B
// Task 8). A new writer joins this list only with the lock.
var slackTokenWriters = []string{
	"cmd/slack.go:connectSlackAccount",
	"cmd/slack.go:removeSlackAccount",
	"cmd/slack_legacy.go:ensureLegacySlackAccount",
	"cmd/slack_connect.go:writeConnectedAccount", // Task 7's connect write, once it lands
	"internal/slackauth/fresh.go:freshLocked",
	"internal/purge/run.go:deleteTokens",
}

// TestSlackTokenWriters_AllLocked finds every Save/Delete on a Slack token
// store in cmd/ and internal/ (outside internal/slack, which defines them)
// and fails on one outside slackTokenWriters, or in a listed function that
// takes no lock.
func TestSlackTokenWriters_AllLocked(t *testing.T) {
	var found []string
	for _, root := range []string{".", "../internal"} {
		err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				if filepath.ToSlash(path) == "../internal/slack" {
					return filepath.SkipDir
				}
				return nil
			}
			if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
				return nil
			}
			rel := strings.TrimPrefix(filepath.ToSlash(path), "../")
			if root == "." {
				rel = "cmd/" + rel
			}
			for _, fn := range slackTokenWritersIn(t, path) {
				site := rel + ":" + fn.name
				found = append(found, site)
				assert.Contains(t, slackTokenWriters, site, "%s writes a Slack token file outside the locked writers", site)
				assert.True(t, fn.locks, "%s writes a Slack token file (or its row's app ids) without TokenStore.Lock", site)
			}
			return nil
		})
		require.NoError(t, err)
	}
	// The guard must see the writers it lists, or it checks nothing.
	for _, want := range []string{"cmd/slack.go:connectSlackAccount", "cmd/slack_legacy.go:ensureLegacySlackAccount",
		"internal/slackauth/fresh.go:freshLocked", "internal/purge/run.go:deleteTokens", "cmd/slack.go:removeSlackAccount"} {
		assert.Contains(t, found, want)
	}
}

type tokenWriter struct {
	name  string
	locks bool
}

// slackTokenWritersIn parses path and returns each top-level function that
// calls (or takes the method value of) Save or Delete on a Slack token
// store: a variable or parameter built by, or typed as, the Slack package's
// TokenStore, or NewTokenStore(...) directly. locks reports whether every
// such site, and every write of the row's app ids in that function, runs
// under the account's lock (siteLocked).
func slackTokenWritersIn(t *testing.T, path string) []tokenWriter {
	t.Helper()
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
	require.NoError(t, err)
	slackPkg := ""
	for _, imp := range file.Imports {
		if p, _ := strconv.Unquote(imp.Path.Value); p == "watchtower/internal/slack" {
			slackPkg = "slack"
			if imp.Name != nil {
				slackPkg = imp.Name.Name
			}
		}
	}
	if slackPkg == "" {
		return nil
	}
	isSlackStore := func(e ast.Expr) bool { // NewTokenStore(...) or *TokenStore
		switch v := e.(type) {
		case *ast.CallExpr:
			sel, ok := v.Fun.(*ast.SelectorExpr)
			return ok && isIdent(sel.X, slackPkg) && sel.Sel.Name == "NewTokenStore"
		case *ast.StarExpr:
			sel, ok := v.X.(*ast.SelectorExpr)
			return ok && isIdent(sel.X, slackPkg) && sel.Sel.Name == "TokenStore"
		}
		return false
	}
	var out []tokenWriter
	// Every function body: declarations and package-level func literals
	// (a seam like `var save = func(...) {...}` is a writer too).
	type body struct {
		name   string
		params *ast.FieldList
		block  *ast.BlockStmt
	}
	var bodies []body
	for _, decl := range file.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			if d.Body != nil {
				bodies = append(bodies, body{d.Name.Name, d.Type.Params, d.Body})
			}
		case *ast.GenDecl:
			for _, spec := range d.Specs {
				vs, ok := spec.(*ast.ValueSpec)
				if !ok {
					continue
				}
				for i, v := range vs.Values {
					if lit, ok := v.(*ast.FuncLit); ok && i < len(vs.Names) {
						bodies = append(bodies, body{vs.Names[i].Name, lit.Type.Params, lit.Body})
					}
				}
			}
		}
	}
	for _, fn := range bodies {
		stores := map[string]bool{}
		for _, f := range fn.params.List {
			if isSlackStore(f.Type) {
				for _, n := range f.Names {
					stores[n.Name] = true
				}
			}
		}
		writes, locked, rowUnlocked := false, true, false
		lockCalled := map[string]bool{} // stores with an X.Lock(...) call so far
		var stack []ast.Node
		ast.Inspect(fn.block, func(n ast.Node) bool {
			if n == nil {
				stack = stack[:len(stack)-1]
				return true
			}
			stack = append(stack, n)
			switch v := n.(type) {
			case *ast.AssignStmt:
				for i, rhs := range v.Rhs {
					if i < len(v.Lhs) && isSlackStore(rhs) {
						if id, ok := v.Lhs[i].(*ast.Ident); ok {
							stores[id.Name] = true
						}
					}
				}
			case *ast.CallExpr:
				if sel, ok := v.Fun.(*ast.SelectorExpr); ok && sel.Sel.Name == "Lock" {
					if id, ok := sel.X.(*ast.Ident); ok && stores[id.Name] {
						lockCalled[id.Name] = true
					}
				}
				// The row's app ids are written in the same lock section as
				// the token file (tracked item: connect saves the file, then
				// the client id).
				if slices.Contains(slackRowAppWriters, calleeName(v.Fun)) &&
					len(lockCalled) == 0 && !siteLocked(stack, nil, nil) {
					rowUnlocked = true
				}
			case *ast.SelectorExpr:
				if v.Sel.Name != "Save" && v.Sel.Name != "Delete" {
					break
				}
				id, _ := v.X.(*ast.Ident)
				if (id == nil || !stores[id.Name]) && !isSlackStore(v.X) {
					break
				}
				writes = true
				if !siteLocked(stack, id, lockCalled) {
					locked = false
				}
			}
			return true
		})
		if writes {
			out = append(out, tokenWriter{name: fn.name, locks: locked && !rowUnlocked})
		}
	}
	return out
}

// siteLocked reports whether a Save/Delete on store (nil: a store built in
// place) runs under the account's lock: after a store.Lock(...) call in the
// same function, inside a withSlackTokenLock call, or as an argument of a
// call that also gets store.Lock (purge's deleteLocked).
func siteLocked(stack []ast.Node, store *ast.Ident, lockCalled map[string]bool) bool {
	if store != nil && lockCalled[store.Name] {
		return true
	}
	for _, n := range stack {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			continue
		}
		if isIdent(call.Fun, "withSlackTokenLock") {
			return true
		}
		for _, arg := range call.Args {
			if sel, ok := arg.(*ast.SelectorExpr); ok && sel.Sel.Name == "Lock" && store != nil && isIdent(sel.X, store.Name) {
				return true
			}
		}
	}
	return false
}

// slackRowAppWriters write an account row's client and app ids.
var slackRowAppWriters = []string{"recordSlackClientID", "SetSlackAccountApp", "SetSlackAccountClientID", "repairRow"}

// calleeName is f's name: an identifier or a selector's last part.
func calleeName(f ast.Expr) string {
	switch v := f.(type) {
	case *ast.Ident:
		return v.Name
	case *ast.SelectorExpr:
		return v.Sel.Name
	}
	return ""
}

func isIdent(e ast.Expr, name string) bool {
	id, ok := e.(*ast.Ident)
	return ok && id.Name == name
}

// wireSlackSyncers reads tokens through LoadFresh: a refresh that fails for
// now still wires the stored token (the Slack phase retries every cycle); a
// dead refresh token leaves the account unwired in the Re-login state.
func TestWireSlackSyncers_RefreshFailures(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test", Workspaces: map[string]*config.WorkspaceConfig{"test": {}}}
	database := db.OpenTestDB(t)
	due := func(id int64) {
		require.NoError(t, database.SetSlackAccountApp(id, "111.222", ""))
		require.NoError(t, watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), id).Save(&watchtowerslack.Token{
			AccessToken: "xoxe.xoxp-old", TeamID: "T0ACME", RefreshToken: "xoxe-1-old",
			ExpiresAt: time.Now().Add(-time.Minute), ClientID: "111.222",
		}))
	}
	offline, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T0ACME"})
	require.NoError(t, err)
	due(offline)

	original := slackTokenRefresher
	slackTokenRefresher = func() slackauth.Refresher {
		return func(context.Context, string, string) (slackauth.Refreshed, error) {
			return slackauth.Refreshed{}, errors.New("dial tcp: network is unreachable")
		}
	}
	t.Cleanup(func() { slackTokenRefresher = original })
	orchs := wireSlackSyncers(context.Background(), database, cfg, quietTestLogger())
	require.Len(t, orchs, 1, "a transient refresh failure keeps the account wired")
	acct, err := database.GetSlackAccount(offline)
	require.NoError(t, err)
	assert.Equal(t, "ok", acct.Status)

	slackTokenRefresher = func() slackauth.Refresher {
		return func(context.Context, string, string) (slackauth.Refreshed, error) {
			return slackauth.Refreshed{}, &slackauth.RefreshError{Code: "invalid_refresh_token"}
		}
	}
	orchs = wireSlackSyncers(context.Background(), database, cfg, quietTestLogger())
	assert.Empty(t, orchs, "a dead refresh token is not wired")
	acct, err = database.GetSlackAccount(offline)
	require.NoError(t, err)
	assert.Equal(t, "error", acct.Status)
	assert.Equal(t, slackauth.ReloginMessage, acct.Error)
}

// A remove holds the account's token lock from the token read through the
// revoke and the delete, so a refresh racing it cannot rotate in a token
// that was never revoked; once it is done, a refresh finds no file.
func TestSlackRemove_HoldsTheTokenLockThroughRevoke(t *testing.T) {
	cfg, store, id := setupSlackRemove(t)
	require.NoError(t, store.Save(&watchtowerslack.Token{
		AccessToken: "xoxe.xoxp-acme", TeamID: "T1", RefreshToken: "xoxe-1-r",
		ExpiresAt: time.Now().Add(-time.Minute), ClientID: "111.222",
	}))
	held := make(chan bool, 4) // the server goroutine reports, the test reads
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		unlock, ok, err := fsutil.TryLockFile(store.Path() + ".lock")
		if err == nil && ok {
			unlock()
		}
		held <- err == nil && !ok
		_, _ = w.Write([]byte(`{"ok":true,"revoked":true}`))
	}))
	t.Cleanup(srv.Close)
	old := slackRevokeAPIURL
	slackRevokeAPIURL = srv.URL + "/"
	t.Cleanup(func() { slackRevokeAPIURL = old })

	cmd := &cobra.Command{}
	cmd.SetOut(&bytes.Buffer{})
	require.NoError(t, runSlackRemove(cmd, []string{strconv.FormatInt(id, 10)}))
	srv.Close() // waits for in-flight handlers: every send is done
	var heldDuringRevoke []bool
	for len(held) > 0 {
		heldDuringRevoke = append(heldDuringRevoke, <-held)
	}
	assert.Equal(t, []bool{true}, heldDuringRevoke, "auth.revoke runs under the account's token lock")

	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	original := slackTokenRefresher
	slackTokenRefresher = func() slackauth.Refresher {
		return func(context.Context, string, string) (slackauth.Refreshed, error) {
			t.Error("a refresh after the remove must find no token to rotate")
			return slackauth.Refreshed{}, errors.New("unexpected")
		}
	}
	t.Cleanup(func() { slackTokenRefresher = original })
	tok, err := loadSlackToken(context.Background(), cfg, database, id)
	require.NoError(t, err)
	assert.Nil(t, tok)
}
