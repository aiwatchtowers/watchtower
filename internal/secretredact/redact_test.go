package secretredact

import "testing"

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
	} {
		if got := Text(s); got != s {
			t.Fatalf("Text(%q) changed to %q", s, got)
		}
	}
}
