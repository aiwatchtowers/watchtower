package company

import (
	"bytes"
	"encoding/xml"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/companybundle"
	"watchtower/internal/policy"
)

// decodePlist decodes an XML property list into dict → map[string]any,
// array → []any, string → string, integer → int, true/false → bool.
func decodePlist(t *testing.T, raw []byte) any {
	t.Helper()
	dec := xml.NewDecoder(bytes.NewReader(raw))
	dec.Strict = true
	for {
		tok, err := dec.Token()
		require.NoError(t, err)
		if se, ok := tok.(xml.StartElement); ok {
			require.Equal(t, "plist", se.Name.Local)
			v, err := plistValue(dec)
			require.NoError(t, err)
			return v
		}
	}
}

func nextStart(dec *xml.Decoder) (xml.StartElement, bool, error) {
	for {
		tok, err := dec.Token()
		if err != nil {
			return xml.StartElement{}, false, err
		}
		switch tok := tok.(type) {
		case xml.StartElement:
			return tok, true, nil
		case xml.EndElement:
			return xml.StartElement{}, false, nil
		}
	}
}

func plistValue(dec *xml.Decoder) (any, error) {
	se, ok, err := nextStart(dec)
	if err != nil || !ok {
		return nil, fmt.Errorf("no value: %v", err)
	}
	return plistElem(dec, se)
}

func plistElem(dec *xml.Decoder, se xml.StartElement) (any, error) {
	switch se.Name.Local {
	case "dict":
		out := map[string]any{}
		for {
			k, ok, err := nextStart(dec)
			if err != nil {
				return nil, err
			}
			if !ok {
				return out, nil
			}
			var key string
			if err := dec.DecodeElement(&key, &k); err != nil {
				return nil, err
			}
			v, err := plistValue(dec)
			if err != nil {
				return nil, err
			}
			out[key] = v
		}
	case "array":
		out := []any{}
		for {
			e, ok, err := nextStart(dec)
			if err != nil {
				return nil, err
			}
			if !ok {
				return out, nil
			}
			v, err := plistElem(dec, e)
			if err != nil {
				return nil, err
			}
			out = append(out, v)
		}
	case "string":
		var s string
		err := dec.DecodeElement(&s, &se)
		return s, err
	case "integer":
		var s string
		if err := dec.DecodeElement(&s, &se); err != nil {
			return nil, err
		}
		return strconv.Atoi(s)
	case "true", "false":
		if err := dec.Skip(); err != nil {
			return nil, err
		}
		return se.Name.Local == "true", nil
	}
	return nil, fmt.Errorf("unexpected <%s>", se.Name.Local)
}

func TestMobileconfig_GoldenShape(t *testing.T) {
	wire, err := companybundle.Encode(companybundle.Bundle{V: 1, Company: "Acme",
		Slack: &companybundle.Slack{TeamID: "T0ACME", ClientID: "1111.2222"}})
	require.NoError(t, err)
	n := 0
	raw, err := Mobileconfig("acme", wire, func() string {
		n++
		return fmt.Sprintf("00000000-0000-4000-8000-00000000000%d", n)
	})
	require.NoError(t, err)

	root, ok := decodePlist(t, raw).(map[string]any)
	require.True(t, ok)
	assert.Equal(t, "Configuration", root["PayloadType"])
	assert.Equal(t, "com.watchtower.company.acme", root["PayloadIdentifier"])
	assert.Equal(t, "00000000-0000-4000-8000-000000000001", root["PayloadUUID"])
	assert.Equal(t, 1, root["PayloadVersion"])
	content := root["PayloadContent"].([]any)
	require.Len(t, content, 1)
	p := content[0].(map[string]any)
	assert.Equal(t, "com.apple.ManagedClient.preferences", p["PayloadType"])
	assert.Equal(t, "com.watchtower.company.acme.preferences", p["PayloadIdentifier"])
	assert.Equal(t, "00000000-0000-4000-8000-000000000002", p["PayloadUUID"])
	domain := p["PayloadContent"].(map[string]any)
	require.Len(t, domain, 1)
	assert.Equal(t, "com.watchtower.desktop", policy.Domain)
	forced := domain[policy.Domain].(map[string]any)["Forced"].([]any)
	require.Len(t, forced, 1)
	settings := forced[0].(map[string]any)["mcx_preference_settings"].(map[string]any)
	assert.Equal(t, map[string]any{"CompanyBundle": wire}, settings, "the only key, forced, is the wire form")

	b, err := companybundle.Parse(settings["CompanyBundle"].(string), companybundle.OriginMDM)
	require.NoError(t, err, "the profile's value is a bundle MDM accepts")
	assert.Equal(t, "Acme", b.Company)

	if plutil, err := exec.LookPath("plutil"); err == nil {
		path := filepath.Join(t.TempDir(), "acme.mobileconfig")
		require.NoError(t, os.WriteFile(path, raw, 0o600))
		out, err := exec.Command(plutil, "-lint", path).CombinedOutput()
		assert.NoError(t, err, string(out))
	}
}

func TestMobileconfig_RandomUUIDsAndBadInput(t *testing.T) {
	a, b := NewUUID(), NewUUID()
	assert.NotEqual(t, a, b)
	assert.Regexp(t, regexp.MustCompile(`^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$`), a)

	raw, err := Mobileconfig("acme", "eyJ2IjoxfQ", NewUUID)
	require.NoError(t, err)
	root := decodePlist(t, raw).(map[string]any)
	inner := root["PayloadContent"].([]any)[0].(map[string]any)
	assert.NotEqual(t, root["PayloadUUID"], inner["PayloadUUID"], "each payload has its own UUID")

	for _, slug := range []string{"", "Acme", "draft", "a/b", "acme\n"} {
		_, err := Mobileconfig(slug, "eyJ2IjoxfQ", NewUUID)
		assert.Error(t, err, slug)
	}
	_, err = Mobileconfig("acme", "", NewUUID)
	assert.Error(t, err)

	// A value with XML metacharacters stays well-formed.
	raw, err = Mobileconfig("acme", `a<b>&"c`, NewUUID)
	require.NoError(t, err)
	settings := decodePlist(t, raw).(map[string]any)["PayloadContent"].([]any)[0].(map[string]any)["PayloadContent"].(map[string]any)[policy.Domain].(map[string]any)["Forced"].([]any)[0].(map[string]any)["mcx_preference_settings"].(map[string]any)
	assert.Equal(t, `a<b>&"c`, settings["CompanyBundle"])
	assert.False(t, strings.Contains(string(raw), `a<b>`))
}
