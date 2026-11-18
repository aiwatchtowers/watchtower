package cmd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/db"
)

var companyDraftT0 = time.Date(2026, 11, 17, 9, 30, 0, 0, time.UTC)

func TestCompanyList_DraftState(t *testing.T) {
	store := company.NewStore(t.TempDir())
	state := func() string {
		t.Helper()
		res, err := listCompanies(store, "")
		require.NoError(t, err)
		return res.Draft.State
	}
	assert.Equal(t, "none", state())
	require.NoError(t, store.SaveDraft(company.Draft{Company: "Acme", Services: []string{"google"}, Step: "google"}))
	assert.Equal(t, "ok", state())
	require.NoError(t, os.WriteFile(filepath.Join(store.Dir, "draft.json"), []byte("{"), 0o600))
	assert.Equal(t, "unreadable", state())
	assert.Equal(t, "unreadable", state(), "an unreadable draft is never folded into none")
	require.NoError(t, store.DiscardDraft())
	assert.Equal(t, "none", state())
}

func TestCompanyDraft_SaveShowDiscardCLI(t *testing.T) {
	store := company.NewStore(t.TempDir())
	in := `{"company":"Acme","services":["google"],"step":"google","slack":{},` +
		`"google":{"client_id":"1234-abcd.apps.googleusercontent.com","client_secret":"sample-secret"}}`
	require.NoError(t, saveCompanyDraft(store, strings.NewReader(in), companyDraftT0))

	res, err := showCompanyDraft(store, companyDraftT0)
	require.NoError(t, err)
	raw, err := json.Marshal(res)
	require.NoError(t, err)
	var got map[string]any
	require.NoError(t, json.Unmarshal(raw, &got))
	assert.Equal(t, "ok", got["state"])
	assert.Equal(t, "", got["bad_file"])
	assert.Equal(t, []any{}, got["checked_vendors"])
	draft := got["draft"].(map[string]any)
	assert.Equal(t, "2026-11-17T09:30:00Z", draft["started_at"], "a first save stamps its start")
	assert.Equal(t, "sample-secret", draft["google"].(map[string]any)["client_secret"], "the typed secret resumes")

	err = saveCompanyDraft(store, strings.NewReader(`{"company":"Acme","services":[],"step":"","slack":{"config_token":"x"}}`), companyDraftT0)
	assert.ErrorIs(t, err, company.ErrSlackTokenInDraft)

	require.NoError(t, store.DiscardDraft())
	res, err = showCompanyDraft(store, companyDraftT0)
	require.NoError(t, err)
	raw, err = json.Marshal(res)
	require.NoError(t, err)
	assert.JSONEq(t, `{"state":"none","draft":null,"bad_file":"","checked_vendors":[]}`, string(raw))
}

func TestCompanyDiscover_JSONShape(t *testing.T) {
	ws := t.TempDir()
	require.NoError(t, company.NewStore(ws).Save("acme", companybundle.Bundle{V: 1, Company: "Acme",
		Atlassian: &companybundle.Atlassian{ClientID: "acmeClientId01", ClientSecret: "acme-secret", Site: "https://acme.atlassian.net"}}))
	res, err := discoverCompanyClients(context.Background(), ws, db.OpenTestDB(t), "")
	require.NoError(t, err)
	raw, err := json.Marshal(res)
	require.NoError(t, err)
	assert.NotContains(t, string(raw), "acme-secret")
	assert.JSONEq(t, `{"candidates":[{"vendor":"atlassian","client_id":"acmeClientId01","label":"Acme","source":"stored",`+
		`"source_label":"Acme's saved company setup","has_secret":true}]}`, string(raw))

	empty, err := discoverCompanyClients(context.Background(), t.TempDir(), db.OpenTestDB(t), "")
	require.NoError(t, err)
	raw, err = json.Marshal(empty)
	require.NoError(t, err)
	assert.JSONEq(t, `{"candidates":[]}`, string(raw))
}

func TestCompanyDraftCommandsRegistered(t *testing.T) {
	for _, path := range [][]string{{"draft", "show"}, {"draft", "save"}, {"draft", "discard"}, {"discover"}} {
		c, _, err := companyCmd.Find(path)
		require.NoError(t, err, path)
		assert.Equal(t, path[len(path)-1], c.Name())
	}
	for _, c := range []*cobra.Command{companyDraftShowCmd, companyDiscoverCmd} {
		assert.NotNil(t, c.Flags().Lookup("json"), c.Name())
	}
}
