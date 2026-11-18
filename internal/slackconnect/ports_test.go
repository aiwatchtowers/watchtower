package slackconnect

import "testing"

// TestOAuthPortRanges_Disjoint pins that the Slack connect listener's port is
// in no other loopback OAuth listener's range. None of those ranges is
// exported, so each is listed with the file that owns it; a change there must
// be mirrored here.
func TestOAuthPortRanges_Disjoint(t *testing.T) {
	type portRange struct {
		name     string
		from, to int
	}
	ranges := []portRange{
		{"Slack (internal/auth/oauth.go)", 18491, 18500},
		{"Calendar (internal/calendar/auth.go)", 18501, 18510},
		{"Jira (internal/jira/auth.go)", 18511, 18520},
		{"Gmail (internal/gmail/auth.go)", 18521, 18530},
		{"Outlook/IMAP (internal/imap/outlook_auth.go)", 18531, 18540},
		{"Linear (internal/linear/oauth.go)", 18531, 18535},
		{"Quick Connections (internal/mcpoauth/login.go)", 18541, 18550},
	}
	// Linear sits inside Outlook/IMAP's range: a known overlap that predates
	// this listener (the two never bind at the same moment in practice).
	knownOverlap := map[[2]string]bool{
		{"Outlook/IMAP (internal/imap/outlook_auth.go)", "Linear (internal/linear/oauth.go)"}: true,
	}

	if Port != 18551 {
		t.Fatalf("Port = %d, want 18551 (the link and the manifest's redirect URL carry it)", Port)
	}
	for _, r := range ranges {
		if Port >= r.from && Port <= r.to {
			t.Errorf("Port %d is inside %s's range %d-%d", Port, r.name, r.from, r.to)
		}
	}
	for i, a := range ranges {
		for _, b := range ranges[i+1:] {
			if a.from > b.to || b.from > a.to {
				continue
			}
			if knownOverlap[[2]string{a.name, b.name}] {
				continue
			}
			t.Errorf("%s (%d-%d) overlaps %s (%d-%d)", a.name, a.from, a.to, b.name, b.from, b.to)
		}
	}
}
