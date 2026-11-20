package secretredact

import (
	"runtime"
	"strings"
	"testing"
)

func TestText(t *testing.T) {
	cases := []struct{ name, in, want string }{
		{"slack", "post with xoxb-1234567890-abcdefghij now", "post with [secret] now"},  // leak-check:allow
		{"bare bearer digits", "curl url Bearer abc123", "curl url Bearer [secret]"},     // leak-check:allow
		{"bare bearer dotted", "send Bearer x.y.z now", "send Bearer [secret] now"},      // leak-check:allow
		{"bare bearer dash", "Bearer abc-def", "Bearer [secret]"},                        // leak-check:allow
		{"bare bearer underscore", "Bearer abc_def", "Bearer [secret]"},                  // leak-check:allow
		{"bare bearer mixed case", "Bearer AbCdEf", "Bearer [secret]"},                   // leak-check:allow
		{"bare bearer long capitals", "Bearer ABCDEFGHIJ", "Bearer [secret]"},            // leak-check:allow
		{"bare bearer long token", "Bearer abcdEFGH12345678 end", "Bearer [secret] end"}, // leak-check:allow
		{"bare bearer prose", "Bearer authentication is described", "Bearer authentication is described"},
		{"bare bearer token word", "a Bearer token header", "a Bearer token header"},
		{"bare bearer short capitals", "a Bearer JWT header", "a Bearer JWT header"},
		{"github", "use ghp_abcdefghijklmnopqrstuvwxyz0123 here", "use [secret] here"},                                 // leak-check:allow
		{"github pat", "pat github_pat_11ABCDEFG0abcdefghijkl_xyz done", "pat [secret] done"},                          // leak-check:allow
		{"sk", "key sk-abcdefghijklmnop1234 end", "key [secret] end"},                                                  // leak-check:allow
		{"sk-ant", "k sk-ant-api03-abcdefghijklmnop end", "k [secret] end"},                                            // leak-check:allow
		{"aws", "id AKIAABCDEFGHIJKLMNOP end", "id [secret] end"},                                                      // leak-check:allow
		{"pem", "a\n-----BEGIN RSA PRIVATE KEY-----\nMIIabc\ndef\n-----END RSA PRIVATE KEY-----\nb", "a\n[secret]\nb"}, // leak-check:allow
		{"bearer", "Authorization: Bearer abcdef123456.xyz ok", "Authorization: Bearer [secret] ok"},                   // leak-check:allow
		{"url param", "https://example.com/x?token=abc123&y=1", "https://example.com/x?token=[secret]&y=1"},            // leak-check:allow
		{"env line", "export PASSWORD=hunter2 # note", "export PASSWORD=[secret] # note"},                              // leak-check:allow
		{"github token env", "GITHUB_TOKEN=ghx1 run", "GITHUB_TOKEN=[secret] run"},                                     // leak-check:allow
		{"db password env", "DB_PASSWORD=pw1 run", "DB_PASSWORD=[secret] run"},                                         // leak-check:allow
		{"aws secret env", "AWS_SECRET_ACCESS_KEY=abc/def run", "AWS_SECRET_ACCESS_KEY=[secret] run"},                  // leak-check:allow
		{"client secret", "client_secret=abc&x=1", "client_secret=[secret]&x=1"},                                       // leak-check:allow
		{"access token param", "https://example.com/?access_token=abc1", "https://example.com/?access_token=[secret]"}, // leak-check:allow
		{"jwt", "jwt eyJhbGciOiJI.eyJzdWIiOiIx.c2lnbmF0dXJl end", "jwt [secret] end"},                                  // leak-check:allow
		// Shapes the live line's Bash summaries carry (#2112).
		{"url userinfo", "https://user:pa55@host/x", "https://[secret]@host/x"},                                                       // leak-check:allow
		{"url userinfo in command", "git clone https://bob:s3cret@example.com/r.git", "git clone https://[secret]@example.com/r.git"}, // leak-check:allow
		{"curl -u", "curl -u bob:hunter2 url", "curl -u [secret] url"},                                                                // leak-check:allow
		{"curl --user", "curl --user bob:hunter2 url", "curl --user [secret] url"},                                                    // leak-check:allow
		{"password flag", "login --password hunter2", "login --password [secret]"},                                                    // leak-check:allow
		{"token flag", "gh auth --token abc123 -v", "gh auth --token [secret] -v"},                                                    // leak-check:allow
		{"password flag equals", "login --password=hunter2", "login --password=[secret]"},                                             // leak-check:allow
		{"bearer header", `curl -H "Authorization: Bearer abcdEFGH12345678" url`, `curl -H "Authorization: Bearer [secret]" url`},     // leak-check:allow
		{"password env", "PASSWORD=x9y8z7", "PASSWORD=[secret]"},                                                                      // leak-check:allow
		// Review round 1 (#2112): quoted values.
		{"quoted env double", `API_KEY="v x" run`, "API_KEY=[secret] run"},                           // leak-check:allow
		{"quoted env single", "TOKEN='v' run", "TOKEN=[secret] run"},                                 // leak-check:allow
		{"quoted password flag", `login --password "hunter 2 x" -v`, "login --password [secret] -v"}, // leak-check:allow
		{"quoted -u", `curl -u "bob:pa ss" url`, "curl -u [secret] url"},                             // leak-check:allow
		{"quoted token flag", "gh --token 'a b' x", "gh --token [secret] x"},                         // leak-check:allow
		{"unclosed quote at cut", `login --password "hunter 2`, "login --password [secret]"},         // leak-check:allow
		// Colon, JSON and YAML forms.
		{"json password", `{"password":"hunter2"}`, `{"password":[secret]}`},                                // leak-check:allow
		{"json api key spaced", `{"api_key": "abc123", "n": 1}`, `{"api_key": [secret], "n": 1}`},           // leak-check:allow
		{"yaml password", "password: hunter2", "password: [secret]"},                                        // leak-check:allow
		{"x-api-key header", `curl -H "X-Api-Key: abc123" url`, `curl -H "X-Api-Key: [secret]" url`},        // leak-check:allow
		{"private-token header", `-H "PRIVATE-TOKEN: abc123"`, `-H "PRIVATE-TOKEN: [secret]"`},              // leak-check:allow
		{"cookie header", `-H "Cookie: sid=abc; other=x" url`, `-H "Cookie: [secret]" url`},                 // leak-check:allow
		{"auth basic", `-H "Authorization: Basic dXNlcjpwYXNz"`, `-H "Authorization: Basic [secret]"`},      // leak-check:allow
		{"auth token scheme", `-H "Authorization: token abc123"`, `-H "Authorization: token [secret]"`},     // leak-check:allow
		{"auth lowercase bearer", "authorization: bearer abc", "authorization: bearer [secret]"},            // leak-check:allow
		{"auth unknown scheme", `-H "Authorization: Custom k1 k2" url`, `-H "Authorization: [secret]" url`}, // leak-check:allow
		{"auth json", `{"Authorization": "Bearer abc"}`, `{"Authorization": "Bearer [secret]"}`},            // leak-check:allow
		// Space-separated flags, same names as the = rule.
		{"api-key flag", "x --api-key abc", "x --api-key [secret]"},                      // leak-check:allow
		{"apikey flag", "x --apikey abc", "x --apikey [secret]"},                         // leak-check:allow
		{"access-key flag", "x --access-key abc", "x --access-key [secret]"},             // leak-check:allow
		{"private-key flag", "x --private-key abc", "x --private-key [secret]"},          // leak-check:allow
		{"dash value", "login --password -Xy9 -v", "login --password [secret] -v"},       // leak-check:allow
		{"plain word after token", "pass the --token flag", "pass the --token [secret]"}, // accepted over-redaction
		// user:pass shapes.
		{"url empty user", "redis://:pw@host:6379/0", "redis://[secret]@host:6379/0"},    // leak-check:allow
		{"url @ in password", "https://bob:p@ss@host/x", "https://[secret]@host/x"},      // leak-check:allow
		{"url password with =", "https://u:token=abc@host/x", "https://[secret]@host/x"}, // leak-check:allow
		{"--user=", "curl --user=bob:pw url", "curl --user=[secret] url"},                // leak-check:allow
		{"-u attached", "curl -ubob:pw url", "curl -u[secret] url"},                      // leak-check:allow
		{"mysql -p", "mysql -u root -phunter2 db", "mysql -u root -p[secret] db"},        // leak-check:allow
		{"mysql pwd env", "MYSQL_PWD=hunter2 mysql", "MYSQL_PWD=[secret] mysql"},         // leak-check:allow
		{"any pwd env", "DB_PWD=x1 run", "DB_PWD=[secret] run"},                          // leak-check:allow
		// Vendor shapes.
		{"aws session", "id ASIAABCDEFGHIJKLMNOP end", "id [secret] end"},             // leak-check:allow
		{"slack app", "t xapp-1-A0123456789-abcdef end", "t [secret] end"},            // leak-check:allow
		{"stripe live", "k sk_live_abcdefghijklmnop1234 end", "k [secret] end"},       // leak-check:allow
		{"stripe restricted", "k rk_live_abcdefghijklmnop1234 end", "k [secret] end"}, // leak-check:allow
		{"gitlab", "t glpat-abcdefghijklmnopqrst end", "t [secret] end"},              // leak-check:allow
		{"google", "k AIzaSyA1234567890abcdefghijklmnopqrstuv end", "k [secret] end"}, // leak-check:allow
		// Review round 2 (#2112).
		{"db key env", "DB_KEY=abc run", "DB_KEY=[secret] run"},                                                                                                                  // leak-check:allow
		{"signing key env", "SIGNING_KEY='a b' run", "SIGNING_KEY=[secret] run"},                                                                                                 // leak-check:allow
		{"dotted key", "x.key=abc", "x.key=[secret]"},                                                                                                                            // leak-check:allow
		{"dash key", "tls-key=abc", "tls-key=[secret]"},                                                                                                                          // leak-check:allow
		{"query key first", "https://example.com/m?key=abc&n=1", "https://example.com/m?key=[secret]&n=1"},                                                                       // leak-check:allow
		{"query key later", "https://example.com/m?n=1&key=abc", "https://example.com/m?n=1&key=[secret]"},                                                                       // leak-check:allow
		{"json escaped quote", `{"password":"pa\"ss","n":1}`, `{"password":[secret],"n":1}`},                                                                                     // leak-check:allow
		{"shell escaped quote", `PASSWORD='it\'s' run`, "PASSWORD=[secret] run"},                                                                                                 // leak-check:allow
		{"digest", `curl -H 'Authorization: Digest username="bob", nonce="n1", response="r1"' url`, `curl -H 'Authorization: [secret]' url`},                                     // leak-check:allow
		{"digest double quoted", `-H "Authorization: Digest username=\"bob\", response=\"r1\"" url`, `-H "Authorization: [secret]" url`},                                         // leak-check:allow
		{"digest unquoted line", "Authorization: Digest username=\"bob\", response=\"r1\"\nnext", "Authorization: [secret]\nnext"},                                               // leak-check:allow
		{"two auth headers", `-H "Authorization: Bearer a1" -H "Proxy-Authorization: Basic b2"`, `-H "Authorization: Bearer [secret]" -H "Proxy-Authorization: Basic [secret]"`}, // leak-check:allow
		{"adjacent secret flags", "x --password --token abc1", "x --password --token [secret]"},                                                                                  // leak-check:allow
		{"short flag then secret flag", "x --password -v --token abc1", "x --password -v --token [secret]"},                                                                      // leak-check:allow
		{"curl numeric user", "curl -u 1000:secret url", "curl -u [secret] url"},                                                                                                 // leak-check:allow
		{"curl numeric pair", "curl -u 1000:1000 url", "curl -u [secret] url"},                                                                                                   // leak-check:allow
		{"docker named user", "docker run -u app:pw img", "docker run -u [secret] img"},                                                                                          // leak-check:allow
		// Review round 3 (#2112).
		{"cookie quoted inner value", `-H 'Cookie: session="example"; other=abc' url`, `-H 'Cookie: [secret]' url`}, // leak-check:allow
		{"cookie escaped quote", `-H "Cookie: a=\"x\"; b=y" url`, `-H "Cookie: [secret]" url`},                      // leak-check:allow
		{"set-cookie line", "Set-Cookie: sid=abc; Path=/\nnext", "Set-Cookie: [secret]\nnext"},                      // leak-check:allow
		{"assignment mixed quotes", `export PASSWORD=pre"example value" && x`, "export PASSWORD=[secret] && x"},     // leak-check:allow
		{"assignment adjacent segments", `TOKEN='a'b"c" run`, "TOKEN=[secret] run"},                                 // leak-check:allow
		{"assignment escaped space", `TOKEN=a\ b run`, "TOKEN=[secret] run"},                                        // leak-check:allow
		{"key assignment mixed", `DB_KEY=x"y z" run`, "DB_KEY=[secret] run"},                                        // leak-check:allow
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := Text(c.in); got != c.want {
				t.Fatalf("Text(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

func TestText_LeavesOrdinaryText(t *testing.T) {
	for _, s := range []string{
		"commit 3f786850e387550fdab836ed7e6dc881de23001b fixed it",
		"id 123e4567-e89b-12d3-a456-426614174000",
		"func f() { token := next(); key = 3; max_tokens=5 }",
		"the skill sk-1 and Bearer of news",
		"max_tokens=5 and Bearer authentication is described",
		"plain prose, nothing to see.",
		"go test ./internal/sessionfeed",
		"git push -u origin main",
		"https://user@example.com/x",
		"llm --max-tokens 512 --token-file path",
		"login --password --verbose",
		"see http://localhost:8080/x",
		"docker run -u 1000:1000 img",
		"docker run --rm -it -u 0:0 img sh",
		"podman exec -u 1000:1000 box sh",
		"nerdctl container create -u 10:10 img",
		"key=value sort",
		"echo $PWD/x",
		"tool --key=path/to/file --sort-key=name monkey=banana",
		"gh auth login --with-token < tok.txt",
		"x --token | jq",
		"x --password; echo",
		"x --token && y",
		"x --password > out",
		"mysql -u root -p db",
		"mkdir -p dir",
		"ssh://git@host:22/repo",
		"func f() { token := next() }",
		"max_tokens: 5",
	} {
		if got := Text(s); got != s {
			t.Fatalf("Text(%q) changed to %q", s, got)
		}
	}
}

func TestTextBounded_CutsAfterRedacting(t *testing.T) {
	in := strings.Repeat("a", 190) + " --password hunter2 tail" // leak-check:allow
	got := TextBounded(in, 200)
	if strings.Contains(got, "hunt") {
		t.Fatalf("secret leaked across the cut: %q", got)
	}
	if n := len([]rune(got)); n != 200 {
		t.Fatalf("kept %d runes, want 200", n)
	}
	if got := TextBounded("token=abc ok", 200); got != "token=[secret] ok" { // leak-check:allow
		t.Fatalf("short input: %q", got)
	}
	if got := TextBounded("日本語テキスト", 3); got != "日本語" {
		t.Fatalf("rune cut: %q", got)
	}
	if got := TextBounded("abc", 0); got != "" {
		t.Fatalf("zero limit: %q", got)
	}
}

// A secret straddling the read window is redacted, not cut into a fragment
// the patterns miss: a multi-byte prefix still leaves the slack past the kept
// runes.
func TestTextBounded_MultiByteWindow(t *testing.T) {
	in := strings.Repeat("ж", 180) + " --password " + strings.Repeat("Q1", 400) // leak-check:allow
	if got := TextBounded(in, 200); strings.Contains(got, "Q1") {
		t.Fatalf("secret leaked: %q", got)
	}
}

// TextBounded's work does not grow with its input: a 4 MiB summary allocates
// about what a 4 KiB one does (input-size scaling, not wall time).
func TestTextBounded_WorkBoundedByLimit(t *testing.T) {
	unit := "run --password hunter2 https://u:p@h/x ж " // leak-check:allow
	small := strings.Repeat(unit, 4<<10/len(unit))
	big := strings.Repeat(unit, 4<<20/len(unit))
	if TextBounded(small, 200) != TextBounded(big, 200) {
		t.Fatal("same prefix, different output")
	}
	allocated := func(s string) uint64 {
		var before, after runtime.MemStats
		runtime.GC()
		runtime.ReadMemStats(&before)
		for range 10 {
			TextBounded(s, 200)
		}
		runtime.ReadMemStats(&after)
		return after.TotalAlloc - before.TotalAlloc
	}
	a, b := allocated(small), allocated(big)
	if b > 2*a+64<<10 {
		t.Fatalf("4 MiB input allocated %d bytes vs %d for 4 KiB: work grows with input", b, a)
	}
}

// A URL whose "@" falls past the read window: the kept text ends inside the
// authority, so everything after "://" is masked.
func TestTextBounded_OpenAuthorityAtCut(t *testing.T) {
	in := "clone https://bob:" + strings.Repeat("p", 3000) + "@host/r.git" // leak-check:allow
	if got, want := TextBounded(in, 200), "clone https://[secret]"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
	// Cut by the rune limit inside the authority, @ within the window: the URL
	// rule already redacted it.
	in = strings.Repeat("a", 190) + " https://bob:pw@host/x" // leak-check:allow
	if got := TextBounded(in, 200); strings.Contains(got, "pw") || strings.Contains(got, "bob") {
		t.Fatalf("leaked: %q", got)
	}
	// Not cut: a URL ending the text stays.
	if got := TextBounded("open https://example.com", 200); got != "open https://example.com" {
		t.Fatalf("uncut URL changed: %q", got)
	}
}

// Many headers on one line are one forward pass: 1000 headers cost about ten
// times what 100 do (input-size scaling, not wall time).
func TestText_ManyHeadersLinear(t *testing.T) {
	unit := `-H "Authorization: Bearer abcdEFGH12345678" ` // leak-check:allow
	small, big := strings.Repeat(unit, 100), strings.Repeat(unit, 1000)
	if got := Text(big); strings.Contains(got, "abcdEFGH") || strings.Count(got, Mark) != 1000 {
		t.Fatalf("not every header redacted: %d marks", strings.Count(got, Mark))
	}
	allocated := func(s string) uint64 {
		var before, after runtime.MemStats
		runtime.GC()
		runtime.ReadMemStats(&before)
		Text(s)
		runtime.ReadMemStats(&after)
		return after.TotalAlloc - before.TotalAlloc
	}
	a, b := allocated(small), allocated(big)
	if b > 20*a+64<<10 {
		t.Fatalf("1000 headers allocated %d bytes vs %d for 100: work grows faster than the input", b, a)
	}
}

// A vendor token prefix that runs into the read window's end is masked
// whole: its rule never saw the full shape (a JWT short of its second dot,
// a GitHub token short of 20 characters).
func TestTextWithin_PartialTokenAtWindowEnd(t *testing.T) {
	jwt := "eyJhbGciOiJIUzI1NiJ9" + strings.Repeat("A", 3000) + ".eyJzdWIiOiIxIn0.sig" // leak-check:allow
	if got := TextBounded("auth "+jwt, 200); got != "auth "+Mark {
		t.Fatalf("JWT straddling the window: %q", got)
	}
	if got := TextWithin("auth "+jwt, 1000); got != "auth "+Mark {
		t.Fatalf("TextWithin: %q", got)
	}
	for _, prefix := range []string{
		"ghp_", "github_pat_", "xoxb-", "xapp-", "sk-", "sk_live_", "glpat-", "AIza", "AKIA", "ASIA", // leak-check:allow
	} {
		in := "use " + prefix + "AB12"
		if got := TextWithin(in+strings.Repeat(" x", 10), len(in)); got != "use "+Mark {
			t.Errorf("%s cut at the window: %q", prefix, got)
		}
	}
	// Not cut: a short look-alike stays, and so does a word merely ending
	// in a prefix.
	for _, in := range []string{"use sk-learn", "the task-sk-x", "eyJ"} {
		if got := TextWithin(in, 1000); got != in {
			t.Errorf("uncut %q changed: %q", in, got)
		}
	}
	// A complete token inside the window is redacted by its own rule.
	if got := TextWithin("t ghp_abcdefghijklmnopqrstuvwxyz0123 end", 1000); got != "t "+Mark+" end" { // leak-check:allow
		t.Fatalf("complete token: %q", got)
	}
}
