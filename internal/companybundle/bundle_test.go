package companybundle

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"slices"
	"strings"
	"testing"

	"watchtower/internal/media/linkrule"
)

type fixtureCase struct {
	Name   string  `json:"name"`
	Wire   *string `json:"wire"`
	JSON   *string `json:"json"`
	Origin string  `json:"origin"`
	Want   struct {
		OK      bool            `json:"ok"`
		Reason  string          `json:"reason"`
		Bundle  json.RawMessage `json:"bundle"`
		Slug    string          `json:"slug"`
		Encoded *string         `json:"encoded"`
	} `json:"want"`
}

var origins = map[string]Origin{"link": OriginLink, "mdm": OriginMDM, "code": OriginCode, "local": OriginLocal}

func loadCases(t *testing.T) []fixtureCase {
	t.Helper()
	raw, err := os.ReadFile("testdata/bundle_cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []fixtureCase
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) < 50 {
		t.Fatalf("fixture has %d cases, want the full set", len(cases))
	}
	return cases
}

// canonical decodes JSON into a generic value for a key-order-free compare.
func canonical(t *testing.T, raw []byte) any {
	t.Helper()
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("canonical: %v", err)
	}
	return v
}

func checkResult(t *testing.T, c fixtureCase, path string, b Bundle, err error) {
	t.Helper()
	if !c.Want.OK {
		var pe *ParseError
		if !errors.As(err, &pe) {
			t.Fatalf("%s: err = %v, want refusal %q", path, err, c.Want.Reason)
		}
		if string(pe.Reason) != c.Want.Reason {
			t.Fatalf("%s: reason = %q (%s), want %q", path, pe.Reason, pe.Detail, c.Want.Reason)
		}
		return
	}
	if err != nil {
		t.Fatalf("%s: unexpected refusal: %v", path, err)
	}
	got, mErr := marshal(b)
	if mErr != nil {
		t.Fatal(mErr)
	}
	if !reflect.DeepEqual(canonical(t, got), canonical(t, c.Want.Bundle)) {
		t.Fatalf("%s: bundle = %s, want %s", path, got, c.Want.Bundle)
	}
	if s := Slug(b.Company); s != c.Want.Slug {
		t.Fatalf("%s: slug = %q, want %q", path, s, c.Want.Slug)
	}
}

func TestCompanyBundle_Cases(t *testing.T) {
	for _, c := range loadCases(t) {
		t.Run(c.Name, func(t *testing.T) {
			origin, ok := origins[c.Origin]
			if !ok {
				t.Fatalf("unknown origin %q", c.Origin)
			}
			switch {
			case c.Wire != nil:
				b, err := Parse(*c.Wire, origin)
				checkResult(t, c, "Parse", b, err)
			case c.JSON != nil:
				b, err := ParseJSON([]byte(*c.JSON), origin)
				checkResult(t, c, "ParseJSON", b, err)
				// The same JSON on the wire reads the same.
				b, err = Parse(base64.RawURLEncoding.EncodeToString([]byte(*c.JSON)), origin)
				checkResult(t, c, "Parse(wire)", b, err)
			default:
				t.Fatal("case has neither wire nor json")
			}
		})
	}
}

// TestEncode_RoundTrip: every accepted fixture bundle encodes without
// padding, parses back equal, and (where the fixture pins it) to the exact
// bytes the Swift twin must produce.
func TestEncode_RoundTrip(t *testing.T) {
	n := 0
	for _, c := range loadCases(t) {
		if !c.Want.OK || c.Origin == "local" {
			continue
		}
		b, err := ParseJSON(c.Want.Bundle, OriginLink)
		if err != nil {
			t.Fatalf("%s: want bundle refused: %v", c.Name, err)
		}
		wire, err := Encode(b)
		if err != nil {
			t.Fatalf("%s: Encode: %v", c.Name, err)
		}
		if strings.Contains(wire, "=") {
			t.Fatalf("%s: padding in %q", c.Name, wire)
		}
		back, err := Parse(wire, OriginLink)
		if err != nil || !reflect.DeepEqual(back, b) {
			t.Fatalf("%s: Parse(Encode(b)) = %+v, %v; want %+v", c.Name, back, err, b)
		}
		if c.Want.Encoded != nil {
			n++
			if wire != *c.Want.Encoded {
				t.Fatalf("%s: Encode = %q, want %q", c.Name, wire, *c.Want.Encoded)
			}
		}
	}
	if n == 0 {
		t.Fatal("no fixture case pins an encoding")
	}
}

func TestEncode_RefusesPersonalAndInvalid(t *testing.T) {
	if _, err := Encode(Bundle{V: 1, Company: "Me", Personal: true}); !isReason(err, RefusalPersonal) {
		t.Fatalf("personal: err = %v", err)
	}
	if _, err := Encode(Bundle{V: 1}); !isReason(err, RefusalDamaged) {
		t.Fatalf("no company: err = %v", err)
	}
}

func TestEncode_NormalizesBeforeEncoding(t *testing.T) {
	wire, err := Encode(Bundle{V: 1, Company: " Acme ", Atlassian: &Atlassian{
		ClientID: "acmeClientId01", ClientSecret: "acme-secret", Site: "https://Acme.atlassian.net/",
	}})
	if err != nil {
		t.Fatal(err)
	}
	b, err := Parse(wire, OriginLink)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := base64.RawURLEncoding.DecodeString(wire)
	if b.Company != "Acme" || b.Atlassian.Site != "https://acme.atlassian.net" || strings.Contains(string(raw), "Acme.atlassian") {
		t.Fatalf("not normalized: %s", raw)
	}
}

func TestEncode_TooLong(t *testing.T) {
	b := Bundle{V: 1, Company: "Acme"}
	for i := 0; len(mustEncodeLen(t, b)) <= MaxEncodedLen; i++ {
		b.LinkDenyHosts = append(b.LinkDenyHosts, "host"+strings.Repeat("x", 40)+".example.com")
	}
	if _, err := Encode(b); !isReason(err, RefusalTooLong) {
		t.Fatalf("err = %v, want too_long", err)
	}
}

// mustEncodeLen is the wire form without the cap, for growing a bundle to it.
func mustEncodeLen(t *testing.T, b Bundle) string {
	t.Helper()
	raw, err := marshal(b)
	if err != nil {
		t.Fatal(err)
	}
	return base64.RawURLEncoding.EncodeToString(raw)
}

func TestParse_CapIsInclusive(t *testing.T) {
	// A valid bundle grown (deny list, then company padding) to exactly
	// MaxEncodedLen characters is accepted.
	for hosts := 1; hosts < 200; hosts++ {
		for pad := 0; pad < 40; pad++ {
			b := Bundle{V: 1, Company: "Acme" + strings.Repeat("x", pad)}
			for i := 0; i < hosts; i++ {
				b.LinkDenyHosts = append(b.LinkDenyHosts, "intranet"+strings.Repeat("y", i%5)+".example.com")
			}
			wire := mustEncodeLen(t, b)
			if len(wire) == MaxEncodedLen {
				if _, err := Parse(wire, OriginLink); err != nil {
					t.Fatalf("a %d-character wire refused: %v", len(wire), err)
				}
				return
			}
		}
	}
	t.Fatal("no bundle of exactly MaxEncodedLen characters found")
}

func TestParse_NormalizesSiteAndIDs(t *testing.T) {
	a := Bundle{V: 1, Company: "Acme", Atlassian: &Atlassian{ClientID: "acmeClientId01", ClientSecret: "acme-secret", Site: "https://acme.atlassian.net"}}
	b := Bundle{V: 1, Company: " Acme ", Atlassian: &Atlassian{ClientID: " acmeClientId01 ", ClientSecret: "acme-secret ", Site: "https://Acme.atlassian.net/"}}
	pa := mustParse(t, a)
	pb := mustParse(t, b)
	if !reflect.DeepEqual(pa, pb) {
		t.Fatalf("forms differ after Parse:\n%+v\n%+v", pa.Atlassian, pb.Atlassian)
	}
	if Slug(pa.Company) != Slug(pb.Company) {
		t.Fatal("slugs differ")
	}
}

func mustParse(t *testing.T, b Bundle) Bundle {
	t.Helper()
	raw, err := marshal(b)
	if err != nil {
		t.Fatal(err)
	}
	p, err := Parse(base64.RawURLEncoding.EncodeToString(raw), OriginLink)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestParse_DenyHostsRejectsNonHosts(t *testing.T) {
	hostile := []string{"*", "https://x/", "example.com/path", "10.0.0.0/8", "10.0.0.1", "::1", "[::1]", "*.example.com",
		"example.com:443", "", " ", "localhost", "com", ".example.com", "example.com.", "exa mple.com", "exämple.com",
		"-a.example.com", "a-.example.com", strings.Repeat("a", 64) + ".example.com", strings.Repeat("a.", 130) + "com"}
	for _, h := range hostile {
		raw, _ := json.Marshal(map[string]any{"v": 1, "company": "Acme", "link_deny_hosts": []string{"ok.example.com", h}})
		if _, err := ParseJSON(raw, OriginLink); !isReason(err, RefusalDamaged) {
			t.Errorf("%q: err = %v, want damaged", h, err)
		}
	}
	// DenyHost agrees with Parse on every one of them.
	for _, h := range hostile {
		if _, ok := DenyHost(h); ok {
			t.Errorf("DenyHost(%q) accepted a host Parse refuses", h)
		}
	}
	if h, ok := DenyHost(" Intranet.Example.com "); !ok || h != "intranet.example.com" {
		t.Errorf("DenyHost = %q, %v", h, ok)
	}
	// An accepted list is already in linkrule's normalized form, so it can
	// only add hosts to media.RefusedHosts, never be dropped from it.
	ok := []string{"Intranet.Example.com", " wiki.example.com", "xn--exmple-cua.example.com", "a-b.example.co.uk"}
	raw, _ := json.Marshal(map[string]any{"v": 1, "company": "Acme", "link_deny_hosts": ok})
	b, err := ParseJSON(raw, OriginLink)
	if err != nil {
		t.Fatal(err)
	}
	set := linkrule.NormalizeHostSet(b.LinkDenyHosts)
	if len(set) != len(ok) {
		t.Fatalf("NormalizeHostSet kept %d of %d: %v", len(set), len(ok), set)
	}
	for _, h := range b.LinkDenyHosts {
		if !set[h] {
			t.Fatalf("%q changes under NormalizeHostSet: %v", h, set)
		}
	}
}

func TestSlug_NonASCIIFallsBackToCompany(t *testing.T) {
	cases := map[string]string{
		"Ачме": "company", "": "company", "   ": "company", "---": "company", "株式会社": "company",
		"Acme": "acme", "Acme Inc.": "acme-inc", "acme-inc": "acme-inc", "ACME  inc": "acme-inc",
		"Ачме Acme": "acme", "Acme Ачме 2": "acme-2", "Draft": "draft-company", "draft ": "draft-company",
		strings.Repeat("ab ", 40): strings.TrimRight(strings.Repeat("ab-", 22)[:64], "-"),
	}
	for in, want := range cases {
		if got := Slug(in); got != want {
			t.Errorf("Slug(%q) = %q, want %q", in, got, want)
		}
	}
}

// refusals is every Refusal; the Swift enum holds the same raw values.
var refusals = []Refusal{RefusalDamaged, RefusalTooLong, RefusalSiteNotHTTPS, RefusalPersonal, RefusalNewerVersion}

func TestParse_RefusalReasonsAreClosedSet(t *testing.T) {
	want := []Refusal{"damaged", "too_long", "site_not_https", "personal", "newer_version"}
	if !reflect.DeepEqual(refusals, want) {
		t.Fatalf("refusals = %v, want %v", refusals, want)
	}
	seen := map[string]bool{}
	for _, c := range loadCases(t) {
		if c.Want.OK {
			continue
		}
		if !slices.Contains(refusals, Refusal(c.Want.Reason)) {
			t.Fatalf("%s: reason %q outside the closed set", c.Name, c.Want.Reason)
		}
		seen[c.Want.Reason] = true
	}
	for _, r := range refusals {
		if !seen[string(r)] {
			t.Errorf("no fixture case refuses with %q", r)
		}
	}
}

func TestVendors_FixedOrder(t *testing.T) {
	b := Bundle{Linear: &Linear{}, Microsoft: &Microsoft{}, Atlassian: &Atlassian{}, Google: &Google{}, Slack: &Slack{}}
	if got := b.Vendors(); !reflect.DeepEqual(got, []string{"slack", "google", "atlassian", "microsoft", "linear"}) {
		t.Fatalf("Vendors() = %v", got)
	}
	if got := (Bundle{Linear: &Linear{}, Google: &Google{}}).Vendors(); !reflect.DeepEqual(got, []string{"google", "linear"}) {
		t.Fatalf("Vendors() = %v", got)
	}
	if got := (Bundle{}).Vendors(); len(got) != 0 {
		t.Fatalf("Vendors() = %v", got)
	}
}

func isReason(err error, r Refusal) bool {
	var pe *ParseError
	return errors.As(err, &pe) && pe.Reason == r
}
