package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
)

func runPolicyKeys(t *testing.T, args ...string) string {
	t.Helper()
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&bytes.Buffer{})
	rootCmd.SetArgs(append([]string{"policy", "keys"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	policyKeysFlagJSON = false
	require.NoError(t, err, out.String())
	return out.String()
}

// checkGolden compares got with the repo file at rel (from the repo root);
// -update rewrites it.
func checkGolden(t *testing.T, rel string, got []byte) {
	t.Helper()
	path := filepath.Join("..", filepath.FromSlash(rel))
	if *updateSessionReportGolden {
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
		require.NoError(t, os.WriteFile(path, got, 0o644))
	}
	want, err := os.ReadFile(path)
	require.NoError(t, err, "run go test ./cmd -run %s -update", t.Name())
	assert.Equal(t, string(want), string(got), "%s differs; run go test ./cmd -run %s -update", rel, t.Name())
}

// TestPolicyKeys_JSONEqualsDocsFile pins docs/mdm/keys.json (the IT page's
// key table) to `policy keys --json`: the page cannot list a key the app
// lacks or miss one.
func TestPolicyKeys_JSONEqualsDocsFile(t *testing.T) {
	out := runPolicyKeys(t, "--json")
	var docs []map[string]string
	require.NoError(t, json.Unmarshal([]byte(out), &docs), out)
	require.Len(t, docs, len(policy.KeyDocs()))
	for _, d := range docs {
		wantKeys(t, anyMap(d), "key", "type", "default", "effect")
	}
	checkGolden(t, "docs/mdm/keys.json", []byte(out))
}

// TestPolicySite_JSONEqualsDocsFile pins docs/mdm/site.json, the one copy of
// the IT page address the Desktop reads, to policy.ITGuideURL.
func TestPolicySite_JSONEqualsDocsFile(t *testing.T) {
	b, err := json.MarshalIndent(map[string]string{"url": policy.ITGuideURL}, "", "  ")
	require.NoError(t, err)
	checkGolden(t, "docs/mdm/site.json", append(b, '\n'))
}

func TestPolicyKeys_PlainListsEveryKey(t *testing.T) {
	out := runPolicyKeys(t)
	for _, d := range policy.KeyDocs() {
		assert.Contains(t, out, d.Key+" ("+d.Type+", default "+d.Default+"): ")
	}
	assert.Contains(t, out, "What each key does: "+policy.ITGuideURL+"\n")
}

func TestPolicyShow_NamesITGuide(t *testing.T) {
	policytest.Set(t, nil)
	assert.Contains(t, runPolicyShow(t), "What each key does: "+policy.ITGuideURL+"\n")
}

// TestPolicyShow_CompanyBundleNamesCompanyOnly pins that the text form names
// the forced company and never prints the bundle (it carries client secrets).
func TestPolicyShow_CompanyBundleNamesCompanyOnly(t *testing.T) {
	// {"v":1,"company":"Acme","google":{"client_id":"1234-abcd.apps.googleusercontent.com","client_secret":"sample-secret"}}
	wire := "eyJ2IjoxLCJjb21wYW55IjoiQWNtZSIsImdvb2dsZSI6eyJjbGllbnRfaWQiOiIxMjM0LWFiY2QuYXBwcy5nb29nbGV1c2VyY29udGVudC5jb20iLCJjbGllbnRfc2VjcmV0Ijoic2FtcGxlLXNlY3JldCJ9fQ"
	policytest.Set(t, map[string]any{"CompanyBundle": wire, "AllowOwnGoogleProject": false})
	out := runPolicyShow(t)
	assert.Contains(t, out, "CompanyBundle: Acme\n")
	assert.Contains(t, out, "AllowOwnGoogleProject: not allowed\n")
	assert.Contains(t, out, "AllowAtlassianAPIToken: not set\n")
	assert.NotContains(t, out, wire)
	assert.NotContains(t, out, "sample-secret")

	keys, ok := policyShowJSON(t)["keys"].(map[string]any)
	require.True(t, ok)
	assert.Equal(t, "Acme", keys["CompanyBundle"], "--json names the company, never the bundle")
}

func anyMap(m map[string]string) map[string]any {
	out := make(map[string]any, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}
