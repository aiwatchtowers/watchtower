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

func TestFetchable_FixRound1Refusals(t *testing.T) {
	deny := NormalizeHostSet([]string{"Corp.Example.", "bücher.example"})
	refused := []string{
		// trailing-dot and ideographic-dot hosts
		"https://slack.com../", "https://slack.com。/", "https://corp.example../", "https://wiki.corp.example。/",
		"https://slack.com.../x", "https://a..example.com/",
		"https://xn--bcher-kva.example/", "https://www.bücher.example/",
		// path parameters
		"https://example.com/login;jsessionid=abc", "https://example.com/verify;token=abc", "https://example.com/p;token=abc",
		"https://example.com/p;a=1;sid=abc",
		// ; as query separator
		"https://example.com/p?a=1;token=abc",
		// array keys
		"https://example.com/p?token[]=abc", "https://example.com/p?token%5B%5D=abc", "https://example.com/p?token[0]=abc",
		// tokenized keys
		"https://example.com/p?auth_token=abc", "https://example.com/p?private_token=abc",
		"https://example.com/p?oauth_token=abc", "https://example.com/p?access-token=abc", "https://example.com/p?sort-key=a",
		"https://example.com/p#auth_token=abc",
		// fragment routes
		"https://example.com/app#/invite?token=abc", "https://example.com/app#!/x?access_token=abc",
		"https://example.com/app#/invite/abc", "https://example.com/app#!/reset-password",
		// double encoding
		"https://example.com/lo%2567in", "https://example.com/p?t%256Fken=abc", "https://example.com/a%252Fverify",
		// IP literals
		"https://127.0.0.1/", "https://8.8.8.8/x", "https://[::1]/", "https://[2001:db8::1]/", "https://2130706433/",
	}
	for _, u := range refused {
		if n, ok := Fetchable(u, deny); ok {
			t.Errorf("%s allowed as %s", u, n)
		}
	}
	allowed := []string{
		"https://example.com/p?page_size=10", "https://example.com/p?Expires=1", "https://example.com/p;v=1",
		"https://example.com/app#/docs/intro", "https://example.com/p?keyboard=1", "https://example.com/p?monkey=1",
		"http://x",
	}
	for _, u := range allowed {
		if n, ok := Fetchable(u, deny); !ok {
			t.Errorf("%s refused (%s)", u, n)
		}
	}
}

func TestNormalizeURL_EmptyPath(t *testing.T) {
	a, _ := NormalizeURL("https://example.com")
	b, _ := NormalizeURL("https://example.com/")
	c, _ := NormalizeURL("https://example.com?b=1&a=2")
	if a != b || a != "https://example.com/" || c != "https://example.com/?a=2&b=1" {
		t.Fatalf("%q %q %q", a, b, c)
	}
}

func TestTextLinks_ShortScheme(t *testing.T) {
	if got := TextLinks("see http://x now"); len(got) != 1 || got[0] != "http://x" {
		t.Fatalf("%v", got)
	}
}

func TestNormalizeHostSet(t *testing.T) {
	m := NormalizeHostSet([]string{" Corp.Example. ", "bücher.example", "", "a..b"})
	if !m["corp.example"] || !m["xn--bcher-kva.example"] || len(m) != 2 {
		t.Fatalf("%v", m)
	}
}

func TestFetchable_CamelCaseAndBrackets(t *testing.T) {
	for _, u := range []string{
		"https://example.com/p?accessToken=x", "https://example.com/p?refreshToken=x", "https://example.com/p?clientSecret=x",
		"https://example.com/p?idToken=x", "https://example.com/p?APIKey=x", "https://example.com/p?apiKey=x",
		"https://example.com/p?accesstoken=x", "https://example.com/p#accessToken=x", "https://example.com/p?token2=x",
		"https://example.com/resetPassword", "https://example.com/signIn", "https://example.com/SignIn", "https://example.com/verifyEmail",
		"https://example.com/p?token[=x", "https://example.com/p?token[0=x", "https://example.com/p?accessToken[]=x",
	} {
		if n, ok := Fetchable(u, nil); ok {
			t.Errorf("%s allowed as %s", u, n)
		}
	}
	for _, u := range []string{
		"https://example.com/p?keyboard=1", "https://example.com/p?page_size=1", "https://example.com/p?monkey=1",
		"https://example.com/a#/docs/intro", "https://example.com/blog/approvals", "https://example.com/p?pageSize=1",
	} {
		if _, ok := Fetchable(u, nil); !ok {
			t.Errorf("%s refused", u)
		}
	}
}

func TestFetchable_NestedAndAcronymKeys(t *testing.T) {
	for _, u := range []string{
		"https://example.com/p?user[password]=x", "https://example.com/p?a[token]=x", "https://example.com/p?a[b][accessToken]=x",
		"https://example.com/p?a%5Bsecret%5D=x", "https://example.com/p?a[token=x",
		"https://example.com/p?CSRFToken=x", "https://example.com/p?APISecret=x", "https://example.com/p?AWSToken=x",
		"https://example.com/p?URLSignature=x", "https://example.com/p?APITokenId=x",
		"https://example.com/p#user[password]=x", "https://example.com/p;CSRFToken=x",
	} {
		if n, ok := Fetchable(u, nil); ok {
			t.Errorf("%s allowed as %s", u, n)
		}
	}
	for _, u := range []string{
		"https://example.com/p?utf8=1", "https://example.com/p?h264=1", "https://example.com/p?pageSize=1",
		"https://example.com/p?keyboard=1", "https://example.com/p?filter[name]=x", "https://example.com/p?items[0]=x",
		"https://example.com/p?HTMLPage=1",
	} {
		if _, ok := Fetchable(u, nil); !ok {
			t.Errorf("%s refused", u)
		}
	}
}

func TestFetchable_SessionIDKeys(t *testing.T) {
	for _, k := range []string{"jsessionid", "JSESSIONID", "PHPSESSID", "ASPSESSIONID", "ASPSESSIONIDQABCDEFG", "ASP.NET_SessionId", "sessid", "session_id", "mySessionId"} {
		for _, u := range []string{
			"https://example.com/p?" + k + "=x",
			"https://example.com/p;" + k + "=x",
			"https://example.com/p#" + k + "=x",
		} {
			if n, ok := Fetchable(u, nil); ok {
				t.Errorf("%s allowed as %s", u, n)
			}
		}
	}
	for _, u := range []string{"https://example.com/p?sessions=1", "https://example.com/p?obsessive=1"} {
		if _, ok := Fetchable(u, nil); !ok {
			t.Errorf("%s refused", u)
		}
	}
}
