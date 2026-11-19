package slackconnect

import (
	"errors"
	"testing"
)

func TestParseConnectInput(t *testing.T) {
	want := Target{TeamID: "T0ACME01", ClientID: "1111.2222"}
	cases := []struct {
		name  string
		in    string
		ok    bool
		wantT Target
	}{
		{"link", "http://127.0.0.1:18551/slack/connect?team=T0ACME01&client=1111.2222", true, want},
		{"link params swapped", "http://127.0.0.1:18551/slack/connect?client=1111.2222&team=T0ACME01", true, want},
		{"link enterprise team", "http://127.0.0.1:18551/slack/connect?team=E0ACME01&client=1111.2222", true,
			Target{TeamID: "E0ACME01", ClientID: "1111.2222"}},
		{"code", "T0ACME01:1111.2222", true, want},
		{"code with whitespace", "  T0ACME01:1111.2222\n", true, want},
		{"link with whitespace", "\thttp://127.0.0.1:18551/slack/connect?team=T0ACME01&client=1111.2222 ", true, want},

		{"empty", "", false, Target{}},
		{"spaces only", "   ", false, Target{}},
		{"https scheme", "https://127.0.0.1:18551/slack/connect?team=T0ACME01&client=1111.2222", false, Target{}},
		{"wrong host", "http://example.com:18551/slack/connect?team=T0ACME01&client=1111.2222", false, Target{}},
		{"localhost host", "http://localhost:18551/slack/connect?team=T0ACME01&client=1111.2222", false, Target{}},
		{"wrong port", "http://127.0.0.1:18552/slack/connect?team=T0ACME01&client=1111.2222", false, Target{}},
		{"no port", "http://127.0.0.1/slack/connect?team=T0ACME01&client=1111.2222", false, Target{}},
		{"user info", "http://evil@127.0.0.1:18551/slack/connect?team=T0ACME01&client=1111.2222", false, Target{}},
		{"wrong path", "http://127.0.0.1:18551/callback?team=T0ACME01&client=1111.2222", false, Target{}},
		{"path trailing slash", "http://127.0.0.1:18551/slack/connect/?team=T0ACME01&client=1111.2222", false, Target{}},
		{"fragment", "http://127.0.0.1:18551/slack/connect?team=T0ACME01&client=1111.2222#x", false, Target{}},
		{"missing team", "http://127.0.0.1:18551/slack/connect?client=1111.2222", false, Target{}},
		{"missing client", "http://127.0.0.1:18551/slack/connect?team=T0ACME01", false, Target{}},
		{"repeated team", "http://127.0.0.1:18551/slack/connect?team=T0ACME01&team=T0OTHER1&client=1111.2222", false, Target{}},
		{"lowercase team", "T0acme01:1111.2222", false, Target{}},
		{"team wrong prefix", "U0ACME01:1111.2222", false, Target{}},
		{"team too short", "T0:1111.2222", false, Target{}},
		{"client no dot", "T0ACME01:11112222", false, Target{}},
		{"client letters", "T0ACME01:1111.22a2", false, Target{}},
		{"client two dots", "T0ACME01:1111.2222.3", false, Target{}},
		{"code extra part", "T0ACME01:1111.2222:x", false, Target{}},
		{"code inner space", "T0ACME01: 1111.2222", false, Target{}},
		{"link bad team", "http://127.0.0.1:18551/slack/connect?team=T0ACME01%0A&client=1111.2222", false, Target{}},
		{"javascript url", "javascript:alert(1)", false, Target{}},
		{"javascript url shaped like code", "javascript:1111.2222", false, Target{}},
		{"file url", "file:///etc/passwd", false, Target{}},
		{"file url with params", "file:///slack/connect?team=T0ACME01&client=1111.2222", false, Target{}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ParseConnectInput(tc.in)
			if !tc.ok {
				if !errors.Is(err, ErrNotConnectInput) {
					t.Fatalf("ParseConnectInput(%q) err = %v, want ErrNotConnectInput", tc.in, err)
				}
				if got != (Target{}) {
					t.Fatalf("ParseConnectInput(%q) = %+v on error, want zero", tc.in, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("ParseConnectInput(%q): %v", tc.in, err)
			}
			if got != tc.wantT {
				t.Fatalf("ParseConnectInput(%q) = %+v, want %+v", tc.in, got, tc.wantT)
			}
		})
	}
}

func TestConnectLink_RoundTrips(t *testing.T) {
	tgt := Target{TeamID: "T0ACME01", ClientID: "1111.2222"}
	for _, s := range []string{ConnectLink(tgt), ConnectCode(tgt)} {
		got, err := ParseConnectInput(s)
		if err != nil || got != tgt {
			t.Fatalf("ParseConnectInput(%q) = %+v, %v; want %+v", s, got, err, tgt)
		}
	}
}
