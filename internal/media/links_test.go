package media

import (
	"reflect"
	"strings"
	"testing"
)

func TestSlackLinks(t *testing.T) {
	text := "see <https://example.com/a?x=1&amp;y=2|the page> and <http://example.org/b> " +
		"<@U123> <#C123|general> <!here> <!subteam^S1|grp> <mailto:a@example.com|a@example.com> <ftp://example.com/f>"
	got := SlackLinks(text)
	want := []string{"https://example.com/a?x=1&y=2", "http://example.org/b"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
	if len(SlackLinks("no links here")) != 0 {
		t.Fatal("expected none")
	}
}

func TestTextLinks(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"go to https://example.com/a, then", []string{"https://example.com/a"}},
		{"(see https://example.com/a_(b))", []string{"https://example.com/a_(b)"}},
		{"really? https://example.com/x?y=1! ok", []string{"https://example.com/x?y=1"}},
		{"\"https://example.com/q\" and 'http://example.org/'.", []string{"https://example.com/q", "http://example.org/"}},
		{"[https://example.com/z]", []string{"https://example.com/z"}},
		{"nothing", nil},
	}
	for _, c := range cases {
		got := TextLinks(c.in)
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("%q: got %v want %v", c.in, got, c.want)
		}
	}
}

func TestNormalizeURL(t *testing.T) {
	cases := map[string]string{
		"HTTPS://Example.COM:443/a?b=2&a=1&utm_source=x#frag":      "https://example.com/a?a=1&b=2",
		"http://example.com:80/":                                   "http://example.com/",
		"https://example.com:8080/p":                               "https://example.com:8080/p",
		"https://example.com/p?fbclid=1&gclid=2&mc_cid=3&mc_eid=4": "https://example.com/p",
		"https://UTM.example.com/p?UTM_Medium=x&q=1":               "https://utm.example.com/p?q=1",
		"https://bücher.example/p":                                 "https://xn--bcher-kva.example/p",
	}
	for in, want := range cases {
		got, ok := NormalizeURL(in)
		if !ok || got != want {
			t.Errorf("%q: got %q,%v want %q", in, got, ok, want)
		}
	}
	for _, bad := range []string{"", "not a url", "https://", "://x", "https://exa mple.com/"} {
		if _, ok := NormalizeURL(bad); ok {
			t.Errorf("%q should be unparseable", bad)
		}
	}
}

func TestFetchable_RefusesSecrets(t *testing.T) {
	for _, p := range SecretParams {
		for _, u := range []string{
			"https://example.com/p?" + p + "=v",
			"https://example.com/p?a=1&" + strings.ToUpper(p) + "=v",
			"https://example.com/p#" + p + "=v",
			"https://example.com/p#x=1&" + p + "=v",
		} {
			if n, ok := Fetchable(u, nil); ok {
				t.Errorf("%s allowed as %s", u, n)
			}
		}
	}
	refused := []string{
		"https://example.com/p?X-Amz-Signature=abc",
		"https://example.com/p?x-amz-credential=abc",
		"https://example.com/p?X-Goog-Credential=abc",
		"https://example.com/p#X-Goog-Signature=abc",
		"https://example.com/p?Expires=1&Key-Pair-Id=K1&Policy=x",
		"https://example.com/p?expires=1#key-pair-id=K1",
		"https://user:pw@example.com/",
		"https://user@example.com/",
		"ftp://example.com/",
		"javascript:alert(1)",
		"file:///etc/passwd",
		"data:text/html,hi",
		"//example.com/x",
	}
	for _, u := range refused {
		if n, ok := Fetchable(u, nil); ok {
			t.Errorf("%s allowed as %s", u, n)
		}
	}
	// Expires alone is not a secret.
	if _, ok := Fetchable("https://example.com/p?Expires=1", nil); !ok {
		t.Error("Expires alone should be allowed")
	}
}

func TestFetchable_RefusesSyncedHosts(t *testing.T) {
	for _, u := range []string{
		"https://acme.slack.com/archives/C1",
		"https://slack.com/x",
		"https://files.slack-edge.com/x",
		"https://acme.atlassian.net/browse/X-1",
		"https://docs.google.com/document/d/1",
		"https://drive.google.com/file/d/1",
		"https://linear.app/acme/issue/X-1",
		"https://mail.google.com/mail/u/0",
		"https://calendar.google.com/",
		"https://ACME.Slack.COM./x",
	} {
		if n, ok := Fetchable(u, nil); ok {
			t.Errorf("%s allowed as %s", u, n)
		}
	}
	deny := map[string]bool{"corp.example": true}
	for _, u := range []string{"https://corp.example/a", "https://wiki.corp.example/a"} {
		if _, ok := Fetchable(u, deny); ok {
			t.Errorf("%s allowed", u)
		}
	}
	for _, u := range []string{"https://notcorp.example/a", "https://example.com/linear.app", "https://www.google.com/"} {
		if _, ok := Fetchable(u, deny); !ok {
			t.Errorf("%s refused", u)
		}
	}
}

func TestFetchable_RefusesCapabilityPaths(t *testing.T) {
	for _, s := range SecretPathSegments {
		for _, u := range []string{"https://example.com/" + s, "https://example.com/a/" + s + "/b", "https://example.com/" + strings.ToUpper(s)} {
			if _, ok := Fetchable(u, nil); ok {
				t.Errorf("%s allowed", u)
			}
		}
	}
	for _, p := range []string{
		"/account/reset-password/abc", "/users/verify_email", "/sign-in", "/Log-In", "/%6Cogin", "/a/OAuth", "/x/log.in",
	} {
		if _, ok := Fetchable("https://example.com"+p, nil); ok {
			t.Errorf("%s allowed", p)
		}
	}
	for _, p := range []string{"/blog/resetting-expectations", "/docs/confirmation-page", "/blog/approvals"} {
		if _, ok := Fetchable("https://example.com"+p, nil); !ok {
			t.Errorf("%s refused", p)
		}
	}
}

func TestFetchable_Ports(t *testing.T) {
	for _, u := range []string{"https://example.com:443/a", "http://example.com:80/a", "https://example.com/a"} {
		if _, ok := Fetchable(u, nil); !ok {
			t.Errorf("%s refused", u)
		}
	}
	for _, u := range []string{"https://example.com:8080/a", "https://example.com:22/", "http://example.com:6379/"} {
		if _, ok := Fetchable(u, nil); ok {
			t.Errorf("%s allowed", u)
		}
	}
}

func TestFetchable_AllowsPlain(t *testing.T) {
	got, ok := Fetchable("https://Example.com/post?page=2&utm_source=x", nil)
	if !ok || got != "https://example.com/post?page=2" {
		t.Fatalf("got %q %v", got, ok)
	}
}
