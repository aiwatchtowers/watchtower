package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/spf13/pflag"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/db"
	"watchtower/internal/extract"
	"watchtower/internal/extsync"
	"watchtower/internal/jira"
)

// fakeConfluenceFetcher serves a fixed space list; everything else is empty.
type fakeConfluenceFetcher struct {
	containers []extsync.Container
	err        error
	attachment *extsync.Item   // listed by Changed/All(KindAttachment) when set
	blob       []byte          // its bytes
	failKeys   map[string]bool // spaces whose delta listing fails
}

func (f *fakeConfluenceFetcher) Containers(context.Context) ([]extsync.Container, error) {
	return f.containers, f.err
}
func (f *fakeConfluenceFetcher) Changed(_ context.Context, c extsync.Container, kind extsync.ItemKind, _ time.Time, _ string) ([]extsync.ItemRef, string, error) {
	if f.failKeys[c.Key] {
		return nil, "", errors.New("listing " + c.Key + " failed")
	}
	return f.refs(kind), "", nil
}
func (f *fakeConfluenceFetcher) All(_ context.Context, _ extsync.Container, kind extsync.ItemKind, _ string) ([]extsync.ItemRef, string, error) {
	return f.refs(kind), "", nil
}
func (f *fakeConfluenceFetcher) refs(kind extsync.ItemKind) []extsync.ItemRef {
	if f.attachment == nil || kind != extsync.KindAttachment {
		return nil
	}
	return []extsync.ItemRef{f.attachment.Ref}
}
func (f *fakeConfluenceFetcher) Fetch(_ context.Context, _ extsync.Container, ref extsync.ItemRef) (*extsync.Item, error) {
	if f.attachment != nil && ref.ExtID == f.attachment.Ref.ExtID {
		it := *f.attachment
		return &it, nil
	}
	return nil, nil
}
func (f *fakeConfluenceFetcher) Comments(context.Context, extsync.Container, string) ([]extsync.Item, error) {
	return nil, nil
}
func (f *fakeConfluenceFetcher) Download(context.Context, *extsync.Item, int64) (io.ReadCloser, error) {
	return io.NopCloser(bytes.NewReader(f.blob)), nil
}
func (f *fakeConfluenceFetcher) Users(context.Context, []string) (map[string]extsync.User, error) {
	return nil, nil
}

// confluenceEnv is one test's config + DB + Jira account 1.
type confluenceEnv struct {
	cfg     *config.Config
	db      *db.DB
	fetcher *fakeConfluenceFetcher
}

// setupConfluenceEnv writes a temp config/workspace (the writeKBConfig
// shape), creates Jira account 1 with a token file whose scope is `scope`,
// and injects a fake fetcher.
func setupConfluenceEnv(t *testing.T, scope string) *confluenceEnv {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(configPath, []byte("active_workspace: test\n"), 0o600))
	origConfig := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = origConfig })

	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	database, err := openDBFromConfig()
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })

	id, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c1", SiteURL: "https://acme.atlassian.net", Enabled: true, Status: "ok"})
	require.NoError(t, err)
	require.Equal(t, int64(1), id)
	require.NoError(t, jira.NewTokenStore(cfg.WorkspaceDir(), 1).Save(&jira.OAuthToken{AccessToken: "a", RefreshToken: "r", Scope: scope}))

	fake := &fakeConfluenceFetcher{containers: []extsync.Container{
		{Key: "ENG", Name: "Engineering", ExtID: "100"},
		{Key: "OPS", Name: "Operations", ExtID: "200"},
	}}
	orig := newConfluenceFetcher
	newConfluenceFetcher = func(*jira.Client, string) extsync.Fetcher { return fake }
	t.Cleanup(func() { newConfluenceFetcher = orig })
	return &confluenceEnv{cfg: cfg, db: database, fetcher: fake}
}

func runConfluence(t *testing.T, daemonPID int, args ...string) (string, error) {
	t.Helper()
	origPID := kbDaemonPID
	kbDaemonPID = func() (int, error) { return daemonPID, nil }
	defer func() { kbDaemonPID = origPID }()
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs(append([]string{"confluence"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	confluenceFlagAccount, confluenceSpacesJSON, confluenceStatusJSON, confluenceSyncForce = 0, false, false, false
	confluenceCmd.PersistentFlags().VisitAll(func(f *pflag.Flag) { f.Changed = false })
	for _, c := range confluenceCmd.Commands() {
		c.Flags().VisitAll(func(f *pflag.Flag) { f.Changed = false })
	}
	return out.String(), err
}

func selectedSpaceKeys(t *testing.T, database *db.DB) []string {
	t.Helper()
	srcs, err := database.ListExtSources("confluence")
	require.NoError(t, err)
	keys := []string{}
	for _, s := range srcs {
		keys = append(keys, s.ContainerKey)
	}
	return keys
}

const consentHint = "Confluence access not granted — run: watchtower jira login --account 1 --with-confluence"

func TestConfluenceSelect_WritesSource(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)

	_, err := runConfluence(t, 0, "select", "ENG")
	require.NoError(t, err)

	srcs, err := env.db.ListExtSources("confluence")
	require.NoError(t, err)
	require.Len(t, srcs, 1)
	assert.Equal(t, "ENG", srcs[0].ContainerKey)
	assert.Equal(t, "100", srcs[0].ContainerExtID)
	assert.Equal(t, "Engineering", srcs[0].ContainerName)
	assert.Equal(t, int64(1), srcs[0].JiraAccountID)
}

func TestConfluenceSelect_UnknownKeyWritesNothing(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)

	_, err := runConfluence(t, 0, "select", "ENG", "NOPE")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "NOPE")
	assert.Empty(t, selectedSpaceKeys(t, env.db), "a partly-unknown selection must write nothing")
}

func TestConfluenceUnselect_RemovesSourceAndDocuments(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)
	id, err := env.db.CreateExtSource("confluence", 1, "ENG", "100", "Engineering")
	require.NoError(t, err)
	_, err = env.db.Exec(`INSERT INTO ext_documents (source_id, ext_id, kind) VALUES (?, 'p1', 'page')`, id)
	require.NoError(t, err)

	_, err = runConfluence(t, 0, "unselect", "ENG")
	require.NoError(t, err)

	assert.Empty(t, selectedSpaceKeys(t, env.db))
	var n int
	require.NoError(t, env.db.QueryRow(`SELECT COUNT(*) FROM ext_documents`).Scan(&n))
	assert.Zero(t, n, "unselect must drop the space's synced documents")
}

// TestConfluenceUnselect_RemovedAccountStillUnselects: `jira remove` keeps
// the account's selected spaces (non-destructive), and the Desktop hides a
// removed account — so the CLI unselect is the only way to drop them. It is
// a purely local delete, so a removed account (no token) must not be
// refused when named explicitly.
func TestConfluenceUnselect_RemovedAccountStillUnselects(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)
	id, err := env.db.CreateExtSource("confluence", 1, "ENG", "100", "Engineering")
	require.NoError(t, err)
	_, err = env.db.Exec(`INSERT INTO ext_documents (source_id, ext_id, kind) VALUES (?, 'p1', 'page')`, id)
	require.NoError(t, err)
	require.NoError(t, env.db.SetJiraAccountRemoved(1))
	require.NoError(t, jira.NewTokenStore(env.cfg.WorkspaceDir(), 1).Delete())

	_, err = runConfluence(t, 0, "unselect", "--account", "1", "ENG")
	require.NoError(t, err)

	assert.Empty(t, selectedSpaceKeys(t, env.db))
	var n int
	require.NoError(t, env.db.QueryRow(`SELECT COUNT(*) FROM ext_documents`).Scan(&n))
	assert.Zero(t, n)
}

// TestConfluenceUnselect_RemovedAccountNeedsExplicitFlag: without --account
// the default is still the single enabled account, never a removed one.
func TestConfluenceUnselect_RemovedAccountNeedsExplicitFlag(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)
	_, err := env.db.CreateExtSource("confluence", 1, "ENG", "100", "Engineering")
	require.NoError(t, err)
	require.NoError(t, env.db.SetJiraAccountRemoved(1))

	_, err = runConfluence(t, 0, "unselect", "ENG")
	require.Error(t, err)
	assert.Equal(t, []string{"ENG"}, selectedSpaceKeys(t, env.db))
}

func runJiraRemoveCmd(t *testing.T, id string) (string, error) {
	t.Helper()
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs([]string{"jira", "remove", id})
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	return out.String(), err
}

// TestJiraRemove_HintsKeptConfluenceSpaces: remove keeps the account's
// selected spaces, so it must say how to drop them.
func TestJiraRemove_HintsKeptConfluenceSpaces(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)
	_, err := env.db.CreateExtSource("confluence", 1, "ENG", "100", "Engineering")
	require.NoError(t, err)
	_, err = env.db.CreateExtSource("confluence", 1, "OPS", "200", "Operations")
	require.NoError(t, err)

	out, err := runJiraRemoveCmd(t, "1")
	require.NoError(t, err)
	assert.Contains(t, out, "2 Confluence space(s) kept; run `watchtower confluence unselect --account 1 ENG OPS` to remove them.")
}

func TestJiraRemove_NoSpacesNoHint(t *testing.T) {
	setupConfluenceEnv(t, jira.OAuthScopes)

	out, err := runJiraRemoveCmd(t, "1")
	require.NoError(t, err)
	assert.NotContains(t, out, "Confluence")
}

func TestConfluenceUnselect_UnknownKeyErrors(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)
	_, err := env.db.CreateExtSource("confluence", 1, "ENG", "100", "Engineering")
	require.NoError(t, err)

	_, err = runConfluence(t, 0, "unselect", "ENG", "OPS")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "OPS")
	assert.Equal(t, []string{"ENG"}, selectedSpaceKeys(t, env.db), "nothing is removed when any key is unknown")
}

func TestConfluenceSpaces_JSONMarksSelected(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)
	_, err := env.db.CreateExtSource("confluence", 1, "ENG", "100", "Engineering")
	require.NoError(t, err)

	out, err := runConfluence(t, 0, "spaces", "--json")
	require.NoError(t, err)

	var rows []map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &rows))
	require.Len(t, rows, 2)
	assert.Equal(t, map[string]any{"key": "ENG", "name": "Engineering", "id": "100", "selected": true}, rows[0])
	assert.Equal(t, map[string]any{"key": "OPS", "name": "Operations", "id": "200", "selected": false}, rows[1])
}

func TestConfluenceSpaces_EmptyJSONIsArray(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)
	env.fetcher.containers = nil

	out, err := runConfluence(t, 0, "spaces", "--json")
	require.NoError(t, err)
	assert.JSONEq(t, `[]`, out)
}

func TestConfluence_TokenWithoutScopesShowsReloginHint(t *testing.T) {
	env := setupConfluenceEnv(t, jira.JiraScopes)

	for _, args := range [][]string{{"spaces"}, {"select", "ENG"}} {
		_, err := runConfluence(t, 0, args...)
		require.Error(t, err, "%v", args)
		assert.Equal(t, consentHint, err.Error(), "%v", args)
	}
	assert.Empty(t, selectedSpaceKeys(t, env.db))
}

func TestConfluence_NeedsConsentFromAPIShowsReloginHint(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)
	env.fetcher.err = extsync.ErrNeedsConsent

	_, err := runConfluence(t, 0, "spaces")
	require.Error(t, err)
	assert.Equal(t, consentHint, err.Error())
}

func TestConfluenceStatus_JSONShowsBackfillAndCounts(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)
	id, err := env.db.CreateExtSource("confluence", 1, "ENG", "100", "Engineering")
	require.NoError(t, err)
	_, err = env.db.Exec(`INSERT INTO ext_documents (source_id, ext_id, kind) VALUES (?, 'p1', 'page')`, id)
	require.NoError(t, err)

	out, err := runConfluence(t, 0, "status", "--json")
	require.NoError(t, err)
	var rows []map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &rows))
	require.Len(t, rows, 1)
	assert.Equal(t, "ENG", rows[0]["key"])
	assert.Equal(t, false, rows[0]["backfill_done"])
	assert.Contains(t, rows[0], "last_synced_at")
	assert.EqualValues(t, 1, rows[0]["pages"])

	text, err := runConfluence(t, 0, "status")
	require.NoError(t, err)
	assert.Contains(t, text, "in progress", "a partial backfill must not read as done")
}

func TestConfluenceSync_RefusesWhileDaemonRuns(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)
	_, err := env.db.CreateExtSource("confluence", 1, "ENG", "100", "Engineering")
	require.NoError(t, err)

	_, err = runConfluence(t, 4242, "sync")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "4242")

	out, err := runConfluence(t, 4242, "sync", "--force")
	require.NoError(t, err)
	assert.Contains(t, out, "ENG:")
}

func TestConfluenceSync_ReportsConsentHint(t *testing.T) {
	env := setupConfluenceEnv(t, jira.JiraScopes)
	_, err := env.db.CreateExtSource("confluence", 1, "ENG", "100", "Engineering")
	require.NoError(t, err)

	_, err = runConfluence(t, 0, "sync")
	require.Error(t, err)
	assert.Contains(t, err.Error(), consentHint)
}

// TestExternalSyncWiring_SharesTheJiraClient pins the refresh-safety rule:
// the Confluence fetcher is built over the very *jira.Client instance
// buildAtlassianClients hands the Jira syncer, never a second client.
func TestExternalSyncWiring_SharesTheJiraClient(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)
	// Account 2 has no token file: no client, and it is flagged "error".
	_, err := env.db.CreateJiraAccount(db.JiraAccount{CloudID: "c2", SiteURL: "https://b.atlassian.net", Enabled: true, Status: "ok"})
	require.NoError(t, err)

	var got []*jira.Client
	var sites []string
	newConfluenceFetcher = func(c *jira.Client, site string) extsync.Fetcher {
		got = append(got, c)
		sites = append(sites, site)
		return env.fetcher
	}
	logger := log.New(io.Discard, "", 0)
	env.cfg.Knowledge.Connectors.Enabled = true

	accounts, clients := buildAtlassianClients(env.cfg, env.db, logger)
	require.Len(t, accounts, 2)
	require.Len(t, clients, 1)
	d := daemon.New(env.cfg)
	wireExternalSync(d, env.cfg, env.db, accounts, clients, logger)

	require.Len(t, got, 1)
	assert.Same(t, clients[1], got[0], "the fetcher must ride the Jira syncer's client instance")
	assert.Equal(t, []string{"https://acme.atlassian.net"}, sites)

	acct2, err := env.db.GetJiraAccount(2)
	require.NoError(t, err)
	assert.Equal(t, "error", acct2.Status)
}

func TestExternalSyncWiring_OffBuildsNoFetcher(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)
	called := false
	newConfluenceFetcher = func(*jira.Client, string) extsync.Fetcher { called = true; return env.fetcher }
	env.cfg.Knowledge.Connectors.Enabled = false
	logger := log.New(io.Discard, "", 0)

	accounts, clients := buildAtlassianClients(env.cfg, env.db, logger)
	wireExternalSync(daemon.New(env.cfg), env.cfg, env.db, accounts, clients, logger)
	assert.False(t, called)
}

// TestConfluenceSync_ExtractsAttachments: `confluence sync` wires the
// attachment extractor — an attachment's text lands in ext_documents and
// nothing is left under <workspace>/tmp/extract.
func TestConfluenceSync_ExtractsAttachments(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)
	_, err := env.db.CreateExtSource("confluence", 1, "ENG", "100", "Engineering")
	require.NoError(t, err)
	mod := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	env.fetcher.attachment = &extsync.Item{
		Ref:   extsync.ItemRef{Kind: extsync.KindAttachment, ExtID: "a1", Version: 1, Modified: mod, ParentID: "p1"},
		Title: "notes.txt", MediaType: "text/plain", Size: 11, Download: "/dl/a1",
	}
	env.fetcher.blob = []byte("hello world")

	_, err = runConfluence(t, 0, "sync")
	require.NoError(t, err)
	var status, sections string
	require.NoError(t, env.db.QueryRow(`SELECT extract_status, sections_json FROM ext_documents WHERE ext_id = 'a1'`).
		Scan(&status, &sections))
	assert.Equal(t, "ok", status)
	assert.Contains(t, sections, "hello world")
}

func TestExtSyncOptions_WiresTheExtractor(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)
	logger := log.New(io.Discard, "", 0)
	opts := extSyncOptions(env.cfg, logger, extSyncCycleBudget)
	x, ok := opts.Extractor.(*extract.Extractor)
	require.True(t, ok, "the engine gets the attachment extractor")
	assert.Same(t, logger, x.Logger, "extraction diagnostics go to the extsync logger")
	assert.Equal(t, filepath.Join(env.cfg.WorkspaceDir(), "tmp", "extract"), x.TempDir)
	assert.Nil(t, x.OCR, "no watchtower-ocr next to the test binary: OCR unavailable")
	assert.False(t, x.HasOCR(context.Background()))
	require.Len(t, x.PDFHelper, 2, "PDFs are parsed out of process")
	assert.Equal(t, "extract-pdf-text", x.PDFHelper[1])
	assert.Equal(t, extSyncCycleBudget, opts.Budget)
	require.NotNil(t, opts.ScopesOK)
	require.NotNil(t, opts.Relink, "the engine records Jira-key doc_links")
	require.NoError(t, opts.Relink(context.Background(), env.db, "confluence:1:p1", "covers PROJ-9"))
	links, err := env.db.DocLinksFrom("confluence", "confluence:1:p1")
	require.NoError(t, err)
	require.Len(t, links, 1)
	assert.Equal(t, "PROJ-9", links[0].ToRef)
}

// TestExtSyncOptions_WiresTheOCRHelper: with a watchtower-ocr helper found
// (here through its env override), the extractor gets OCR.
func TestExtSyncOptions_WiresTheOCRHelper(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)
	helper := filepath.Join(t.TempDir(), "watchtower-ocr")
	require.NoError(t, os.WriteFile(helper, []byte("#!/bin/sh\n"), 0o700)) //nolint:gosec // a test helper must be executable
	t.Setenv("WATCHTOWER_OCR_HELPER", helper)
	x, ok := extSyncOptions(env.cfg, log.New(io.Discard, "", 0), 0).Extractor.(*extract.Extractor)
	require.True(t, ok)
	assert.NotNil(t, x.OCR)
	assert.True(t, x.HasOCR(context.Background()))
}

// revokedConfluenceFetcher fails every delta listing as a revoked grant.
type revokedConfluenceFetcher struct{ fakeConfluenceFetcher }

func (revokedConfluenceFetcher) Changed(context.Context, extsync.Container, extsync.ItemKind, time.Time, string) ([]extsync.ItemRef, string, error) {
	return nil, "", extsync.ErrAuthRevoked
}

// TestExtSyncOptions_WiresTheConfluenceHints pins the exact hint texts the
// engine records through the wired extsync.Options.Hints — the Desktop's
// ConfluenceSpacesViewModel.needsConsent keys on "--with-confluence" in
// them (dual path).
func TestExtSyncOptions_WiresTheConfluenceHints(t *testing.T) {
	const revokedHint = "Atlassian sign-in expired — run: watchtower jira login --account 1 --with-confluence"
	sourceError := func(t *testing.T, database *db.DB) (string, string) {
		t.Helper()
		var status, text string
		require.NoError(t, database.QueryRow(`SELECT status, error FROM ext_sources`).Scan(&status, &text))
		return status, text
	}

	t.Run("needs consent", func(t *testing.T) {
		env := setupConfluenceEnv(t, jira.JiraScopes)
		_, err := env.db.CreateExtSource("confluence", 1, "ENG", "100", "Engineering")
		require.NoError(t, err)
		e := extsync.New(env.db, extSyncOptions(env.cfg, log.New(io.Discard, "", 0), 0))
		e.SetFetcher(1, env.fetcher)
		_, err = e.Run(context.Background())
		require.NoError(t, err)
		status, text := sourceError(t, env.db)
		assert.Equal(t, "needs_consent", status)
		assert.Equal(t, consentHint, text)
	})
	t.Run("revoked", func(t *testing.T) {
		env := setupConfluenceEnv(t, jira.OAuthScopes)
		_, err := env.db.CreateExtSource("confluence", 1, "ENG", "100", "Engineering")
		require.NoError(t, err)
		e := extsync.New(env.db, extSyncOptions(env.cfg, log.New(io.Discard, "", 0), 0))
		e.SetFetcher(1, &revokedConfluenceFetcher{})
		_, err = e.Run(context.Background())
		require.NoError(t, err)
		status, text := sourceError(t, env.db)
		assert.Equal(t, "revoked", status)
		assert.Equal(t, revokedHint, text)
	})
}

// A re-login of an account whose grant already carries the Confluence
// scopes keeps requesting them without --with-confluence.
func TestJiraReloginOptions_ScopedTokenKeepsConfluence(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)

	opts, kept, err := jiraReloginOptions(jiraLoginFlagsCmd(t), env.cfg.WorkspaceDir(), env.db, 1)
	require.NoError(t, err)
	assert.True(t, kept)
	assert.True(t, opts.WithConfluence)
}

// Selected spaces keep Confluence even when the stored grant lost the
// scopes (the needs_consent recovery path).
func TestJiraReloginOptions_SelectedSpacesKeepConfluence(t *testing.T) {
	env := setupConfluenceEnv(t, jira.JiraScopes)
	_, err := env.db.CreateExtSource("confluence", 1, "ENG", "100", "Engineering")
	require.NoError(t, err)

	opts, kept, err := jiraReloginOptions(jiraLoginFlagsCmd(t), env.cfg.WorkspaceDir(), env.db, 1)
	require.NoError(t, err)
	assert.True(t, kept)
	assert.True(t, opts.WithConfluence)
}

// A Jira-only account stays Jira-only: no consent-screen change.
func TestJiraReloginOptions_JiraOnlyStaysJiraOnly(t *testing.T) {
	env := setupConfluenceEnv(t, jira.JiraScopes)

	opts, kept, err := jiraReloginOptions(jiraLoginFlagsCmd(t), env.cfg.WorkspaceDir(), env.db, 1)
	require.NoError(t, err)
	assert.False(t, kept)
	assert.Equal(t, jira.LoginOptions{}, opts)

	cmd := jiraLoginFlagsCmd(t)
	require.NoError(t, cmd.Flags().Set("with-confluence", "true"))
	opts, kept, err = jiraReloginOptions(cmd, env.cfg.WorkspaceDir(), env.db, 1)
	require.NoError(t, err)
	assert.False(t, kept, "the explicit flag is not the default kicking in")
	assert.True(t, opts.WithConfluence)
}

// corruptJiraToken overwrites account 1's token file with unparseable JSON.
func corruptJiraToken(t *testing.T, env *confluenceEnv) {
	t.Helper()
	path := jira.NewTokenStore(env.cfg.WorkspaceDir(), 1).Path()
	require.NoError(t, os.WriteFile(path, []byte("{not json"), 0o600))
}

// A missing token file is "not granted" (no error); a corrupt one is an
// error, never "not granted".
func TestConfluenceScopesOK_MissingVsCorruptToken(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)
	ok, err := confluenceScopesOK(env.cfg.WorkspaceDir(), 1)
	require.NoError(t, err)
	assert.True(t, ok)

	ok, err = confluenceScopesOK(env.cfg.WorkspaceDir(), 99)
	require.NoError(t, err, "a missing token file is simply not granted")
	assert.False(t, ok)

	corruptJiraToken(t, env)
	ok, err = confluenceScopesOK(env.cfg.WorkspaceDir(), 1)
	require.Error(t, err)
	assert.False(t, ok)
}

// A corrupt token never blocks a plain re-login (the re-login is what
// replaces it): the decision falls back to the selected spaces, and the
// token error is warned about. Only a failed selected-spaces lookup fails
// the login.
func TestJiraReloginOptions_TokenAndDBErrors(t *testing.T) {
	t.Run("corrupt token, spaces selected: kept", func(t *testing.T) {
		env := setupConfluenceEnv(t, jira.OAuthScopes)
		_, err := env.db.CreateExtSource("confluence", 1, "ENG", "100", "Engineering")
		require.NoError(t, err)
		corruptJiraToken(t, env)
		cmd := jiraLoginFlagsCmd(t)
		var warn bytes.Buffer
		cmd.SetErr(&warn)
		opts, kept, err := jiraReloginOptions(cmd, env.cfg.WorkspaceDir(), env.db, 1)
		require.NoError(t, err)
		assert.True(t, kept)
		assert.True(t, opts.WithConfluence)
		assert.Contains(t, warn.String(), "reading jira account 1 token")
	})
	t.Run("corrupt token, no spaces: Jira-only", func(t *testing.T) {
		env := setupConfluenceEnv(t, jira.OAuthScopes)
		corruptJiraToken(t, env)
		cmd := jiraLoginFlagsCmd(t)
		var warn bytes.Buffer
		cmd.SetErr(&warn)
		opts, kept, err := jiraReloginOptions(cmd, env.cfg.WorkspaceDir(), env.db, 1)
		require.NoError(t, err, "a corrupt token must not block a Jira-only re-login")
		assert.False(t, kept)
		assert.Equal(t, jira.LoginOptions{}, opts)
		assert.Contains(t, warn.String(), "reading jira account 1 token")
	})
	t.Run("db error", func(t *testing.T) {
		env := setupConfluenceEnv(t, jira.JiraScopes)
		require.NoError(t, env.db.Close())
		_, _, err := jiraReloginOptions(jiraLoginFlagsCmd(t), env.cfg.WorkspaceDir(), env.db, 1)
		require.Error(t, err)
		assert.Contains(t, err.Error(), "listing selected Confluence spaces")
		assert.NotContains(t, err.Error(), "--with-confluence")
	})
	t.Run("explicit flag needs no check", func(t *testing.T) {
		env := setupConfluenceEnv(t, jira.OAuthScopes)
		corruptJiraToken(t, env)
		cmd := jiraLoginFlagsCmd(t)
		require.NoError(t, cmd.Flags().Set("with-confluence", "true"))
		opts, _, err := jiraReloginOptions(cmd, env.cfg.WorkspaceDir(), env.db, 1)
		require.NoError(t, err)
		assert.True(t, opts.WithConfluence)
	})
}

// The daemon wiring over a corrupt token records the source as error with
// the read error (and logs it) — never needs_consent — and the CLI reports
// the read error instead of the consent hint.
func TestExtSyncOptions_CorruptTokenIsAnErrorNotConsent(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)
	_, err := env.db.CreateExtSource("confluence", 1, "ENG", "100", "Engineering")
	require.NoError(t, err)
	corruptJiraToken(t, env)

	var logs bytes.Buffer
	e := extsync.New(env.db, extSyncOptions(env.cfg, log.New(&logs, "", 0), 0))
	e.SetFetcher(1, env.fetcher)
	_, err = e.Run(context.Background())
	require.Error(t, err)
	var status, text string
	require.NoError(t, env.db.QueryRow(`SELECT status, error FROM ext_sources`).Scan(&status, &text))
	assert.Equal(t, "error", status)
	assert.Contains(t, text, "reading jira account 1 token")
	assert.Contains(t, logs.String(), "reading jira account 1 token")

	_, err = runConfluence(t, 0, "spaces")
	require.Error(t, err)
	assert.NotEqual(t, consentHint, err.Error())
	assert.Contains(t, err.Error(), "reading jira account 1 token")
}

// TestConfluence_RevokedFromAPIShowsSignInHint: a revoked grant met while
// listing spaces maps to the sign-in-expired hint, not a raw API error.
func TestConfluence_RevokedFromAPIShowsSignInHint(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)
	env.fetcher.err = extsync.ErrAuthRevoked

	for _, args := range [][]string{{"spaces"}, {"select", "ENG"}} {
		_, err := runConfluence(t, 0, args...)
		require.Error(t, err, "%v", args)
		assert.Equal(t, "Atlassian sign-in expired — run: watchtower jira login --account 1 --with-confluence", err.Error(), "%v", args)
	}
	assert.Empty(t, selectedSpaceKeys(t, env.db))
}

// TestConfluenceSync_ContinuesPastAFailingSpace: like the daemon, a failing
// space does not stop the next one; every failure is reported and the
// command exits non-zero.
func TestConfluenceSync_ContinuesPastAFailingSpace(t *testing.T) {
	env := setupConfluenceEnv(t, jira.OAuthScopes)
	for _, k := range []string{"ENG", "OPS", "QA"} {
		_, err := env.db.CreateExtSource("confluence", 1, k, k+"-id", k)
		require.NoError(t, err)
	}
	env.fetcher.failKeys = map[string]bool{"ENG": true, "QA": true}

	out, err := runConfluence(t, 0, "sync")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "2 of 3 space(s) failed")
	assert.Contains(t, err.Error(), "listing ENG failed")
	assert.Contains(t, err.Error(), "listing QA failed")
	assert.Contains(t, out, "OPS: 0 fetched", "the space after a failing one still syncs")

	status := map[string]string{}
	srcs, err := env.db.ListExtSources("confluence")
	require.NoError(t, err)
	for _, s := range srcs {
		status[s.ContainerKey] = s.Status
	}
	assert.Equal(t, map[string]string{"ENG": "error", "OPS": "ok", "QA": "error"}, status)
}
