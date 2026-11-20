package secretredact

import (
	"runtime"
	"strings"
	"testing"
)

func TestText(t *testing.T) {
	cases := []struct{ name, in, want string }{
		{"slack", "post with xoxb-1234567890-abcdefghij now", "post with [secret] now"},                                // leak-check:allow
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
