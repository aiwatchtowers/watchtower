package slackapp

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const fakeSecret = "s3cr3t-client-secret-value"

// slackServer answers each method with body and records what arrived.
func slackServer(t *testing.T, bodies map[string]string) (*Client, *[]*http.Request, *[]string) {
	t.Helper()
	var reqs []*http.Request
	var forms []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.NoError(t, r.ParseForm())
		reqs = append(reqs, r)
		forms = append(forms, r.PostForm.Encode())
		method := strings.TrimPrefix(r.URL.Path, "/")
		if method == "redirect" {
			http.Redirect(w, r, "/auth.test", http.StatusFound)
			return
		}
		body, ok := bodies[method]
		if !ok {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return NewClient(srv.URL), &reqs, &forms
}

func TestClient_CreateDropsTheSecret(t *testing.T) {
	c, reqs, forms := slackServer(t, map[string]string{
		"apps.manifest.create": `{"ok":true,"app_id":"A0NEW","credentials":{"client_id":"1111.2222","client_secret":"` + fakeSecret +
			`","verification_token":"vt","signing_secret":"ss"},"oauth_authorize_url":"https://slack.com/oauth","team_id":"T0ACME"}`,
	})
	m, err := BuildManifest(Link{TeamID: "T0ACME"})
	require.NoError(t, err)
	appID, clientID, err := c.Create(context.Background(), cfgToken, m)
	require.NoError(t, err)
	assert.Equal(t, "A0NEW", appID)
	assert.Equal(t, "1111.2222", clientID)
	require.Len(t, *reqs, 1)
	r := (*reqs)[0]
	assert.Equal(t, "Bearer "+cfgToken, r.Header.Get("Authorization"))
	assert.NotContains(t, r.URL.String(), cfgToken)
	assert.NotContains(t, (*forms)[0], "xoxe", "the token is never in the form")
	var sent Manifest
	require.NoError(t, json.Unmarshal([]byte(r.PostForm.Get("manifest")), &sent))
	assert.Equal(t, m.LongDescription(), sent.LongDescription())
}

func TestClient_Errors(t *testing.T) {
	c, _, _ := slackServer(t, map[string]string{
		"auth.test":            `{"ok":false,"error":"invalid_auth"}`,
		"apps.manifest.create": `{"ok":false,"error":"invalid_manifest","errors":[{"code":"cannot_disable_once_enabled","pointer":"/settings/token_rotation_enabled"}]}`,
		"apps.manifest.export": `{"ok":false,"error":"no_permission"}`,
		"apps.manifest.update": `{"ok":false,"error":"app_not_found"}`,
	})
	ctx := context.Background()
	_, _, err := c.Team(ctx, cfgToken)
	assert.Equal(t, KindBadToken, failure(err).Kind)
	_, _, err = c.Create(ctx, cfgToken, Manifest{})
	f := failure(err)
	assert.Equal(t, KindRefused, f.Kind)
	assert.Equal(t, "invalid_manifest", f.Code)
	assert.Contains(t, err.Error(), "cannot_disable_once_enabled at /settings/token_rotation_enabled")
	_, err = c.Export(ctx, cfgToken, "A0X")
	assert.Equal(t, KindNotCollaborator, failure(err).Kind)
	err = c.Update(ctx, cfgToken, "A0X", Manifest{})
	assert.Equal(t, KindAppNotFound, failure(err).Kind)
}

func TestClient_TeamAndExport(t *testing.T) {
	c, _, forms := slackServer(t, map[string]string{
		"auth.test":            `{"ok":true,"team_id":"T0ACME","team":"Acme","expires_in":43200}`,
		"apps.manifest.export": `{"ok":true,"manifest":{"display_information":{"name":"Acme"},"credentials":{"client_secret":"` + fakeSecret + `"}}}`,
	})
	id, name, err := c.Team(context.Background(), cfgToken)
	require.NoError(t, err)
	assert.Equal(t, "T0ACME", id)
	assert.Equal(t, "Acme", name)
	m, err := c.Export(context.Background(), cfgToken, "A0CORP")
	require.NoError(t, err)
	_, creds := m["credentials"]
	assert.False(t, creds)
	assert.Equal(t, "app_id=A0CORP", (*forms)[1])
}

func TestClient_RefusesRedirectAndHTTPErrors(t *testing.T) {
	c, reqs, _ := slackServer(t, map[string]string{})
	_, err := c.Export(context.Background(), cfgToken, "A0X") // 404
	require.Error(t, err)
	assert.Equal(t, KindNetwork, failure(err).Kind)

	err = c.call(context.Background(), "redirect", cfgToken, nil, nil)
	require.Error(t, err)
	assert.True(t, errors.Is(err, errRedirect), err.Error())
	for _, r := range *reqs {
		assert.NotEqual(t, "/auth.test", r.URL.Path, "the redirect is never followed")
	}
}
