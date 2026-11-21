package connectplay

import "regexp"

// revealPages names, per vendor, the pages and buttons that put a secret on
// the screen (spec §10, "Pages that show a secret"), as case-insensitive
// regular expressions over a step's text. A step that names one must be the
// customer's alone ("**You only:**"): the agent fills the form up to that
// button, calls request_secret and leaves the click to the customer.
var revealPages = map[string][]string{
	// Create on the OAuth client form opens a dialog showing the client secret.
	"google": {`(press|click|tap|hit)\w*\s+\*\*Create\*\*`, `\bdialog\b`},
	// The app's Settings page shows its client secret.
	"atlassian": {`\*\*Settings\*\*`},
	// Generate Token shows the app configuration token.
	"slack": {`Generate Token`},
}

var revealRes = func() map[string][]*regexp.Regexp {
	out := map[string][]*regexp.Regexp{}
	for vendor, phrases := range revealPages {
		for _, p := range phrases {
			out[vendor] = append(out[vendor], regexp.MustCompile(`(?i)`+p))
		}
	}
	return out
}()

// revealVendor is the vendor whose reveal pages a playbook's steps may reach:
// the company vendor, or the vendor behind a personal service.
func revealVendor(p Playbook) string {
	switch p.Service {
	case "company":
		return p.Vendor
	case "slack":
		return "slack"
	case "google", "google_own_project":
		return "google"
	case "jira":
		return "atlassian"
	}
	return ""
}

func matchesAny(res []*regexp.Regexp, s string) bool {
	for _, re := range res {
		if re.MatchString(s) {
			return true
		}
	}
	return false
}
