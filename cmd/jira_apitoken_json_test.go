package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/jira"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/purge"
)

// TestJiraAPIToken_JSONResults (#1887 C5): with --json, add and re-auth
// print one line the Desktop's token sheet reads — a result per expected
// outcome (exit 0), "failed" with Go's message (exit non-zero) otherwise —
// and never the token.
func TestJiraAPIToken_JSONResults(t *testing.T) {
	timeout := &url.Error{Op: "Get", URL: "https://acme.atlassian.net/rest/api/3/myself", Err: context.DeadlineExceeded}
	noHost := &url.Error{Op: "Get", URL: "https://acme.atlassian.net/_edge/tenant_info",
		Err: &net.OpError{Op: "dial", Net: "tcp", Err: &net.DNSError{Err: "no such host", Name: "acme.atlassian.net"}}}
	refused := &url.Error{Op: "Get", URL: "https://acme.atlassian.net/rest/api/3/myself",
		Err: &net.OpError{Op: "dial", Net: "tcp", Err: errors.New("connect: connection refused")}}
	for _, c := range []struct {
		name      string
		tenantErr error
		probeErr  error
		want      apiTokenResult
		fails     bool
	}{
		{name: "ok", want: apiTokenResult{Result: "ok", AccountID: 1, Site: "https://acme.atlassian.net", Email: "person@example.com"}},
		{name: "unauthorized", probeErr: jira.ErrAPITokenDead, want: apiTokenResult{Result: "unauthorized"}},
		{name: "scope", probeErr: &jira.ScopeError{Scope: "read:jira-work"}, want: apiTokenResult{Result: "missing_scope", Scope: "read:jira-work"}},
		{name: "not cloud", tenantErr: jira.ErrNotAtlassianCloud, want: apiTokenResult{Result: "not_cloud"}},
		{name: "timeout", probeErr: timeout, want: apiTokenResult{Result: "network", Detail: "the request timed out"}},
		{name: "no host", tenantErr: noHost, want: apiTokenResult{Result: "network", Detail: "no such host"}},
		{name: "refused", probeErr: refused, want: apiTokenResult{Result: "network", Detail: "connect: connection refused"}},
		{name: "other", probeErr: errors.New("500 Internal Server Error"),
			want: apiTokenResult{Result: "failed", Message: "checking the API token: 500 Internal Server Error"}, fails: true},
	} {
		t.Run(c.name, func(t *testing.T) {
			h := newAPITokenHarness(t)
			h.tenantErr, h.probeErr = c.tenantErr, c.probeErr
			flags := addTokenFlags()
			flags["json"] = "true"
			cmd, out := newTokenCmd(t, jiraAddCmd, flags, cmdTestAPIToken)
			err := runJiraAdd(cmd, nil)
			if c.fails {
				require.Error(t, err)
			} else {
				require.NoError(t, err)
			}
			var got apiTokenResult
			require.NoError(t, json.Unmarshal(out.Bytes(), &got), out.String())
			assert.Equal(t, c.want, got)
			assert.NotContains(t, out.String(), cmdTestAPIToken)
			if c.want.Result != "ok" {
				assert.Empty(t, h.accounts(t), "nothing is stored")
			}
		})
	}

	t.Run("policy", func(t *testing.T) {
		h := newAPITokenHarness(t)
		policytest.Set(t, map[string]any{"AllowAtlassianAPIToken": false})
		flags := addTokenFlags()
		flags["json"] = "true"
		cmd, out := newTokenCmd(t, jiraAddCmd, flags, cmdTestAPIToken)
		require.NoError(t, runJiraAdd(cmd, nil))
		assert.JSONEq(t, `{"result":"forbidden"}`, out.String())
		assert.Empty(t, h.tenantAsks)
	})

	t.Run("re-auth", func(t *testing.T) {
		h := newAPITokenHarness(t)
		a := addTokenAccount(t, h)
		require.NoError(t, h.database.SetJiraAccountAuthState(a.ID, "error", jira.CodeAPITokenDead))
		withJiraAccountFlag(t, a.ID)
		const next = "ATATT-next-not-real" // leak-check:allow
		cmd, out := newTokenCmd(t, jiraLoginCmd, map[string]string{"api-token-stdin": "true", "json": "true"}, next)
		require.NoError(t, runJiraLogin(cmd, nil))
		var got apiTokenResult
		require.NoError(t, json.Unmarshal(out.Bytes(), &got), out.String())
		assert.Equal(t, apiTokenResult{Result: "ok", AccountID: a.ID, Site: "https://acme.atlassian.net", Email: "person@example.com"}, got)
		assert.NotContains(t, out.String(), next)

		h.probeErr = jira.ErrAPITokenDead
		cmd, out = newTokenCmd(t, jiraLoginCmd, map[string]string{"api-token-stdin": "true", "json": "true"}, next)
		require.NoError(t, runJiraLogin(cmd, nil))
		assert.JSONEq(t, `{"result":"unauthorized"}`, out.String())

		// The replace sheet's other ends: the policy forbids tokens (exit 0,
		// the sheet closes), and an OAuth site (failed, non-zero).
		policytest.Set(t, map[string]any{"AllowAtlassianAPIToken": false})
		cmd, out = newTokenCmd(t, jiraLoginCmd, map[string]string{"api-token-stdin": "true", "json": "true"}, next)
		require.NoError(t, runJiraLogin(cmd, nil))
		assert.JSONEq(t, `{"result":"forbidden"}`, out.String())
		policytest.Set(t, map[string]any{})
		oauthID, err := h.database.CreateJiraAccount(db.JiraAccount{CloudID: "c2", SiteURL: "https://other.atlassian.net"})
		require.NoError(t, err)
		withJiraAccountFlag(t, oauthID)
		cmd, out = newTokenCmd(t, jiraLoginCmd, map[string]string{"api-token-stdin": "true", "json": "true"}, next)
		require.Error(t, runJiraLogin(cmd, nil))
		require.NoError(t, json.Unmarshal(out.Bytes(), &got), out.String())
		assert.Equal(t, "failed", got.Result)
		assert.Contains(t, got.Message, "signs in with OAuth")
	})
}

// TestJiraAccountsJSON_PurgeLease (#1887 §6.3): `jira accounts --json`
// carries each account's PURGE-01 lease day only while the lease counts —
// purge on under a rule with leases, the account not stopped by the policy —
// and not once the deadline is under purge.Grace away (the next pass
// schedules the purge; its own line then says when).
func TestJiraAccountsJSON_PurgeLease(t *testing.T) {
	h := newAPITokenHarness(t)
	a := addTokenAccount(t, h)
	require.NoError(t, h.database.SetJiraAccountAuthState(a.ID, "error", jira.CodeAPITokenDead))
	access := time.Now().UTC().Add(-24 * time.Hour).Truncate(time.Second)
	setAccess := func(at time.Time) {
		t.Helper()
		_, err := h.database.Exec(`UPDATE jira_accounts SET access_ok_at = ? WHERE id = ?`, at.Format(time.RFC3339), a.ID)
		require.NoError(t, err)
	}
	setAccess(access)

	lease := func() string {
		t.Helper()
		cmd, out := cmdWithFlags(t, jiraAccountsCmd, map[string]string{"json": "true"})
		require.NoError(t, runJiraAccounts(cmd, nil))
		var rows []jiraAccountJSON
		require.NoError(t, json.Unmarshal(out.Bytes(), &rows), out.String())
		require.Len(t, rows, 1)
		return rows[0].PurgeLeaseAt
	}

	assert.Empty(t, lease(), "purge off by default: no lease")
	policytest.Set(t, map[string]any{"PurgeRevokedData": true})
	assert.Equal(t, access.Add(purge.Lease).Format(time.RFC3339), lease())
	setAccess(time.Now().UTC().Add(-purge.Lease + purge.Grace - time.Hour))
	assert.Empty(t, lease(), "under Grace away: the purge line takes over")
	setAccess(access)
	policytest.Set(t, map[string]any{"PurgeRevokedData": true, "AllowAtlassianAPIToken": false})
	assert.Empty(t, lease(), "POLICY-03 holds a stopped token site's lease")

	// The cut-off follows the managed notice (purge.EffectiveGrace).
	soon := time.Now().UTC().Add(-purge.Lease + time.Hour).Truncate(time.Second)
	setAccess(soon)
	policytest.Set(t, map[string]any{"PurgeRevokedData": true, "PurgeGraceHours": int64(0)})
	assert.Equal(t, soon.Add(purge.Lease).Format(time.RFC3339), lease(), "grace 0: an hour away still shows")
	setAccess(time.Now().UTC().Add(-time.Minute).Truncate(time.Second))
	policytest.Set(t, map[string]any{"PurgeRevokedData": true, "PurgeGraceHours": int64(720)})
	assert.Empty(t, lease(), "grace 720 (the whole lease): even a fresh deadline is under the notice")
}

// TestJiraAPIToken_ConfluenceProbed (#1887 C5, closes Task 17's "scopes
// recorded, not verified"): with Confluence asked for, the token's
// Confluence access is probed; the Confluence scopes are recorded only when
// it answers, else the site connects with Jira alone and the line says
// confluence:false. Without --with-confluence nothing is probed.
func TestJiraAPIToken_ConfluenceProbed(t *testing.T) {
	for _, reads := range []bool{true, false} {
		t.Run(map[bool]string{true: "reads", false: "jira only"}[reads], func(t *testing.T) {
			h := newAPITokenHarness(t)
			h.noConfluence = !reads
			flags := addTokenFlags()
			flags["json"] = "true"
			flags["with-confluence"] = "true"
			cmd, out := newTokenCmd(t, jiraAddCmd, flags, cmdTestAPIToken)
			require.NoError(t, runJiraAdd(cmd, nil), out.String())
			var got apiTokenResult
			require.NoError(t, json.Unmarshal(out.Bytes(), &got), out.String())
			require.NotNil(t, got.Confluence)
			assert.Equal(t, reads, *got.Confluence)
			assert.Equal(t, "ok", got.Result)
			creds, err := jira.NewTokenStore(h.cfg.WorkspaceDir(), got.AccountID).LoadAPIToken()
			require.NoError(t, err)
			if reads {
				assert.Contains(t, creds.Scope, jira.ConfluenceScopes)
			} else {
				assert.Equal(t, jira.JiraScopes, creds.Scope, "no Confluence grant recorded")
			}

			// A re-auth asks again: the carried-over Confluence is probed with the new token.
			withJiraAccountFlag(t, got.AccountID)
			h.noConfluence = true
			probes := h.confluenceProbes
			cmd, out = newTokenCmd(t, jiraLoginCmd, map[string]string{"api-token-stdin": "true", "json": "true"}, "ATATT-next") // leak-check:allow
			require.NoError(t, runJiraLogin(cmd, nil), out.String())
			got = apiTokenResult{}
			require.NoError(t, json.Unmarshal(out.Bytes(), &got), out.String())
			if reads {
				assert.Equal(t, probes+1, h.confluenceProbes)
				require.NotNil(t, got.Confluence)
				assert.False(t, *got.Confluence)
			} else {
				assert.Nil(t, got.Confluence, "nothing to carry over: not asked")
			}
		})
	}

	h := newAPITokenHarness(t)
	flags := addTokenFlags()
	flags["json"] = "true"
	cmd, out := newTokenCmd(t, jiraAddCmd, flags, cmdTestAPIToken)
	require.NoError(t, runJiraAdd(cmd, nil), out.String())
	assert.Zero(t, h.confluenceProbes)
	assert.NotContains(t, out.String(), "confluence")
}

// A Confluence check with no verdict (unreachable, 429, 5xx) is never read
// as "no Confluence": the command fails before anything is stored.
func TestJiraAPIToken_ConfluenceUnknownStoresNothing(t *testing.T) {
	h := newAPITokenHarness(t)
	h.confluenceErr = &url.Error{Op: "Get", URL: "https://acme.atlassian.net/wiki/api/v2/spaces", Err: context.DeadlineExceeded}
	flags := addTokenFlags()
	flags["json"] = "true"
	flags["with-confluence"] = "true"
	cmd, out := newTokenCmd(t, jiraAddCmd, flags, cmdTestAPIToken)
	require.NoError(t, runJiraAdd(cmd, nil))
	assert.JSONEq(t, `{"result":"network","detail":"the request timed out"}`, out.String())
	assert.Empty(t, h.accounts(t))
}
