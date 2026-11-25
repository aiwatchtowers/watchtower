package company

import (
	"fmt"
	"strings"

	"watchtower/internal/slackapp"
	"watchtower/internal/slackconnect"
	"watchtower/internal/slackmanifest"
)

// ConnectLink is a company's connect link: the bundle's wire form handed to
// the employee's own Watchtower on the loopback listener.
func ConnectLink(wire string) string {
	return fmt.Sprintf("http://127.0.0.1:%d/company/connect?b=%s", slackconnect.Port, wire)
}

// AboutText is the company's text on the Slack app's About page (`company
// publish`), laid out as sections:
//
//	Watchtower for <company>
//
//	How to connect
//	1. Open Watchtower.
//	2. Click this link: <link>
//	   If it does not open, paste the code below in Watchtower → Connections → Company code.
//
//	Company code
//	<code>
//
//	No Watchtower yet? Download it: <release page>
//
// When the text and the scope and AI disclosures do not fit Slack's
// long_description cap, the download paragraph goes first, then the code
// (its fallback line and the Company code section); the link is never cut.
// When nothing fits, the last, shortest candidate is returned and the
// caller's own check against the cap (slackmanifest.Description) reports it.
func AboutText(company, link, code string) string {
	header := "Watchtower for " + company + "\n\nHow to connect\n"
	open := "Open Watchtower."
	clickStep := "Click this link: " + link
	withCode := clickStep + "\n   If it does not open, paste the code below in Watchtower → Connections → Company code."
	withCodeSection := header + numberedSteps(open, withCode) + "\n\nCompany code\n" + code
	download := "\n\nNo Watchtower yet? Download it: " + slackapp.ReleasePage

	candidates := []string{
		withCodeSection + download,
		withCodeSection,
		header + numberedSteps(open, clickStep),
	}
	for _, text := range candidates {
		if _, err := slackmanifest.Description(text); err == nil {
			return text
		}
	}
	return candidates[len(candidates)-1]
}

// numberedSteps numbers steps from 1, one per line.
func numberedSteps(steps ...string) string {
	lines := make([]string, len(steps))
	for i, step := range steps {
		lines[i] = fmt.Sprintf("%d. %s", i+1, step)
	}
	return strings.Join(lines, "\n")
}
