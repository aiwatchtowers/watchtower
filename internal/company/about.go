package company

import (
	"fmt"

	"watchtower/internal/slackapp"
	"watchtower/internal/slackconnect"
	"watchtower/internal/slackmanifest"
)

// ConnectLink is a company's connect link: the bundle's wire form handed to
// the employee's own Watchtower on the loopback listener.
func ConnectLink(wire string) string {
	return fmt.Sprintf("http://127.0.0.1:%d/company/connect?b=%s", slackconnect.Port, wire)
}

// aboutLeadsWithCode puts the connect code before the link in the Slack
// About text. Spike S1.2 (is a URL in long_description clickable on About?)
// is still open; the plan's default is that it is, so the link leads. Flip
// this one value when S1.2 answers "no".
const aboutLeadsWithCode = false

// AboutText is the company's text on the Slack app's About page (`company
// publish`): "Watchtower for <company> — connect: <link>", the connect code
// for when the link does not open, and where to get Watchtower. When the
// text and the scope and AI disclosures do not fit Slack's long_description
// cap, the download line goes first, then the second way in (the code, or
// the link when the code leads); the leading one is never cut. The caller
// still checks the result against the cap (slackmanifest.Description).
func AboutText(company, link, code string) string {
	first := "Watchtower for " + company + " — connect: " + link
	second := "Connect code: " + code + " — paste it in Watchtower → Connections → Connect with a company code if the link does not open."
	if aboutLeadsWithCode {
		first = "Watchtower for " + company + " — connect code: " + code + " — paste it in Watchtower → Connections → Connect with a company code."
		second = "Or open this link with Watchtower running: " + link
	}
	tail := "Open Watchtower first. No Watchtower yet? Download it from " + slackapp.ReleasePage + "."
	for _, text := range []string{first + "\n" + second + "\n" + tail, first + "\n" + second} {
		if _, err := slackmanifest.Description(text); err == nil {
			return text
		}
	}
	return first
}
