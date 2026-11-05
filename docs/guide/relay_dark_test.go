package guide

import (
	"io/fs"
	"os"
	"path"
	"regexp"
	"strings"
	"testing"
)

// relayNotYetLine opens every Relay passage a phone user can read until the
// release that sets the relay origin (ask #1012, Phase 4 Open decision 16).
// The test walks iphone* pages only: features/headless-host.md, concepts/privacy.md
// and the headless host entry in README.md carry the line unguarded, so an edit there
// checks it by hand.
const relayNotYetLine = "Relay isn't in the current version of Watchtower for iPhone."

// cardsHeldUntilLaunch are Learn cards that would send a phone user to something
// their build lacks, whatever their id says. Removed with the line at launch.
var cardsHeldUntilLaunch = []string{"iphone-relay-subscribe", "iphone-alerts-relay", "headless-host-run"}

func readGuidePage(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(name)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// firstTextAfter returns the first line after the heading that is neither blank
// nor a learn comment. An empty result fails the caller's comparison.
func firstTextAfter(t *testing.T, page, heading string) string {
	t.Helper()
	_, rest, found := strings.Cut("\n"+page, "\n"+heading+"\n")
	if !found {
		t.Fatalf("no heading %q", heading)
	}
	for _, line := range strings.Split(rest, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "<!--") {
			continue
		}
		return line
	}
	return ""
}

func TestRelayGuideSaysNotYet(t *testing.T) {
	var relayPages int
	err := fs.WalkDir(os.DirFS("."), ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		name := path.Base(p)
		if d.IsDir() || !strings.HasPrefix(name, "iphone") || path.Ext(name) != ".md" {
			return nil
		}
		page := readGuidePage(t, p)
		if !strings.Contains(strings.ToLower(page), "relay") {
			return nil
		}
		relayPages++
		if !strings.Contains(page, relayNotYetLine) {
			t.Errorf("%s mentions Relay without the line %q", p, relayNotYetLine)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	// iphone.md, iphone-relay.md, iphone-alerts.md, iphone-not-delivered.md and
	// troubleshooting/iphone-not-syncing.md: fewer means the walk found nothing to check.
	if relayPages < 5 {
		t.Errorf("found %d iphone pages that mention Relay, want at least 5", relayPages)
	}

	var entry string
	for _, line := range strings.Split(readGuidePage(t, "README.md"), "\n") {
		if strings.Contains(line, "features/iphone-relay.md") {
			entry = line
		}
	}
	if !strings.HasSuffix(entry, " — "+relayNotYetLine) {
		t.Errorf("README's entry for iphone-relay.md = %q, its description must be the line exactly", entry)
	}

	for _, section := range []struct{ file, heading string }{
		{"features/iphone-relay.md", "# iPhone: Relay"},
		{"features/iphone-alerts.md", "### Alerts over Relay"},
		{"features/iphone-not-delivered.md", "### Over Relay"},
		{"features/iphone.md", "### Relay"},
	} {
		if got := firstTextAfter(t, readGuidePage(t, section.file), section.heading); got != relayNotYetLine && !strings.HasPrefix(got, relayNotYetLine+" ") {
			t.Errorf("%s: the first text under %q is %q, want the line", section.file, section.heading, got)
		}
	}

	cardID := regexp.MustCompile(`(?m)^id:\s*(\S*relay\S*)\s*$`)
	cardBlock := regexp.MustCompile(`(?s)<!-- learn\b.*?-->`)
	err = fs.WalkDir(os.DirFS("."), ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || path.Ext(p) != ".md" || p == "WRITING.md" {
			return nil
		}
		for _, block := range cardBlock.FindAllString(readGuidePage(t, p), -1) {
			if m := cardID.FindStringSubmatch(block); m != nil {
				t.Errorf("%s has the Learn card %q: Relay cards wait for launch", p, m[1])
			}
			for _, held := range cardsHeldUntilLaunch {
				if regexp.MustCompile(`(?m)^id:\s*` + regexp.QuoteMeta(held) + `\s*$`).MatchString(block) {
					t.Errorf("%s has the Learn card %q: it is held until launch", p, held)
				}
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
