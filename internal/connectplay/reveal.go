package connectplay

import (
	"regexp"
	"strings"
)

// revealPages names, per vendor, the pages and buttons that put a secret on
// the screen (spec §10, "Pages that show a secret"), as case-insensitive
// regular expressions over a step's text with its Markdown formatting removed
// (bold, code, italics), so "**Create**", "`Create`" and "Create" all match.
// A step that names one must be the customer's alone ("**You only:**"): the
// agent fills the form up to that button, calls request_secret and leaves the
// click to the customer. The patterns err on the safe side: a false positive
// costs a rewording, a miss lets the agent reveal a secret.
var revealPages = map[string][]string{
	// Create on the OAuth client form opens a dialog showing the client secret.
	"google": {`\b(press|click|tap|hit|select|choose)\w*\s+(on\s+)?(the\s+)?Create\b`, `\bdialog\b`},
	// The app's Settings page shows its client secret.
	"atlassian": {`\bSettings\b`},
	// Generate Token shows the app configuration token.
	"slack": {`\bGenerate\s+Token\b`},
}

// markup is the inline Markdown formatting stripped before matching.
var markup = strings.NewReplacer("*", "", "`", "", "_", " ")

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
	s = markup.Replace(s)
	for _, re := range res {
		if re.MatchString(s) {
			return true
		}
	}
	return false
}
