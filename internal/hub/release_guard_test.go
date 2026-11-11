package hub

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// Relay client Phase 5, launch condition 4 (ask #1066): no build with a set
// relay origin has left development, so "no old relay build" holds. The
// change that sets the Release origin at launch deletes this test in the same
// PR.
//
// The phone's setting is WATCHTOWER_RELAY_ORIGIN. .github/workflows/
// linux-build.yml sets RELAY_ORIGIN, the Linux hub's own variable under
// another name; it does not match, and the workflow scan below pins that it
// does not set the phone's.
//
// Amended by ask #1156 ("every TestFlight build talks to the staging relay"):
// make mobile-testflight may set the origin, and only as the shell variable
// it reads through scripts/testflight-relay-origin.sh from
// RELAY_TESTFLIGHT_ORIGIN_FILE, a file under $(HOME) outside the repo. A
// literal origin there is still refused, and mobile-archive (the App Store
// review build), the project files, plists, the xcconfig and every other
// script stay dark.

var phoneOriginSetting = regexp.MustCompile(`WATCHTOWER_RELAY_ORIGIN(?:\[[^\]]*\])*\s*[:=]\s*(.*)`)

// nonEmptyOriginValues returns the non-empty values text assigns to the
// phone's relay origin setting.
func nonEmptyOriginValues(text string) []string {
	var out []string
	for _, line := range strings.Split(text, "\n") {
		// A documented example in a comment is not a setting.
		if t := strings.TrimSpace(line); strings.HasPrefix(t, "//") || strings.HasPrefix(t, "#") {
			continue
		}
		m := phoneOriginSetting.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		v := m[1]
		if i := strings.Index(v, "#"); i >= 0 {
			v = v[:i]
		}
		v = strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(v), ";"))
		v = strings.Trim(v, `"'`)
		if v != "" {
			out = append(out, v)
		}
	}
	return out
}

// makeTarget returns the text of one Makefile target: its line and the lines
// up to the next target.
func makeTarget(t *testing.T, makefile, name string) string {
	t.Helper()
	lines := strings.Split(makefile, "\n")
	var out []string
	in := false
	for _, l := range lines {
		if strings.HasPrefix(l, name+":") {
			in = true
			out = append(out, l)
			continue
		}
		if in && regexp.MustCompile(`^[A-Za-z0-9_.-]+:`).MatchString(l) {
			break
		}
		if in {
			out = append(out, l)
		}
	}
	if !in {
		t.Fatalf("Makefile has no %s target", name)
	}
	return strings.Join(out, "\n")
}

// scriptMayBuildPhone says whether a scripts/ file could archive or upload
// the phone: it mentions archive, mobile-archive or testflight, whether or
// not it names WatchtowerMobile (a wrapper may call `make mobile-archive`).
// The relay-interop stand scripts set an origin for local test runs.
func scriptMayBuildPhone(name, text string) bool {
	if strings.HasPrefix(name, "relay-interop") {
		return false
	}
	l := strings.ToLower(text)
	return strings.Contains(l, "archive") || strings.Contains(l, "testflight")
}

func readRepoFile(t *testing.T, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", rel))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestNoReleasePhoneBuildSetsRelayOrigin(t *testing.T) {
	texts := map[string]string{
		"WatchtowerMobile/Base.xcconfig": readRepoFile(t, "WatchtowerMobile/Base.xcconfig"),
		"WatchtowerMobile/project.yml":   readRepoFile(t, "WatchtowerMobile/project.yml"),
	}
	makefile := readRepoFile(t, "Makefile")
	for _, target := range []string{"mobile-archive", "mobile-testflight"} {
		texts["Makefile:"+target] = makeTarget(t, makefile, target)
	}
	texts["WatchtowerMobile/WatchtowerMobile.xcodeproj/project.pbxproj"] = readRepoFile(t, "WatchtowerMobile/WatchtowerMobile.xcodeproj/project.pbxproj")
	texts["WatchtowerMobile/ExportOptions.plist"] = readRepoFile(t, "WatchtowerMobile/ExportOptions.plist")
	// The origin reaches the app only through Info.plist's WTRelayOrigin,
	// which must stay a build-setting reference.
	info := readRepoFile(t, "WatchtowerMobile/Info.plist")
	if !regexp.MustCompile(`<key>WTRelayOrigin</key>\s*<string>\$\(WATCHTOWER_RELAY_ORIGIN\)</string>`).MatchString(info) {
		t.Error("Info.plist's WTRelayOrigin must be exactly $(WATCHTOWER_RELAY_ORIGIN), a hard-coded origin would bypass the build settings")
	}
	// Scripts that archive the phone; the relay-interop stand scripts set an
	// origin for local test runs and do not build a release.
	scripts, _ := filepath.Glob(filepath.Join("..", "..", "scripts", "*"))
	for _, sc := range scripts {
		b, err := os.ReadFile(sc)
		if err != nil || !scriptMayBuildPhone(filepath.Base(sc), string(b)) {
			continue
		}
		texts["scripts/"+filepath.Base(sc)] = string(b)
	}
	workflows, err := filepath.Glob(filepath.Join("..", "..", ".github", "workflows", "*"))
	if err != nil || len(workflows) == 0 {
		t.Fatalf("no workflow files found: %v", err)
	}
	for _, w := range workflows {
		b, err := os.ReadFile(w)
		if err != nil {
			t.Fatal(err)
		}
		texts[".github/workflows/"+filepath.Base(w)] = string(b)
	}

	// The guard must not go vacuous if the setting is renamed.
	if !strings.Contains(texts["WatchtowerMobile/Base.xcconfig"], "WATCHTOWER_RELAY_ORIGIN") {
		t.Fatal("Base.xcconfig no longer names WATCHTOWER_RELAY_ORIGIN; update this guard to the phone's new setting")
	}
	if strings.Contains(texts["Makefile:mobile-archive"], "WATCHTOWER_RELAY_ORIGIN") {
		t.Error("the mobile-archive target names WATCHTOWER_RELAY_ORIGIN: the App Store review build stays dark (ask #1156)")
	}
	for _, p := range testflightOriginProblems(makefile, texts["Makefile:mobile-testflight"]) {
		t.Error(p)
	}
	if hosts := nonPlaceholderHosts(texts["scripts/"+testflightOriginScript]); len(hosts) > 0 {
		t.Errorf("scripts/%s names real hosts %q: the origin lives only in the file outside the repo", testflightOriginScript, hosts)
	}
	for name, text := range texts {
		if name == "Makefile:mobile-testflight" {
			continue // checked by testflightOriginProblems
		}
		if vals := nonEmptyOriginValues(text); len(vals) > 0 {
			t.Errorf("%s sets WATCHTOWER_RELAY_ORIGIN to %q: a build with a relay origin must not leave development (launch condition 4, ask #1066)", name, vals)
		}
	}
}

const testflightOriginScript = "testflight-relay-origin.sh"

// testflightOriginRead is the one way mobile-testflight gets its origin: the
// script's output for the file named by RELAY_TESTFLIGHT_ORIGIN_FILE.
const testflightOriginRead = `origin=$$(bash scripts/` + testflightOriginScript + ` "$(RELAY_TESTFLIGHT_ORIGIN_FILE)"`

var (
	makeAssignment = func(name string) *regexp.Regexp {
		return regexp.MustCompile(`(?m)^(?:override\s+|export\s+)?` + name + `\s*(?:\?|:|::|\+|!)?=\s*(.*)$`)
	}
	urlHost = regexp.MustCompile(`https?://([A-Za-z0-9.-]+)`)
)

// testflightOriginProblems lists what breaks ask #1156's allowance: the
// mobile-testflight target sets the phone's origin only to the $$origin it
// read from RELAY_TESTFLIGHT_ORIGIN_FILE, that file's default sits under
// $(HOME) (outside the repo), and nothing in the Makefile gives mobile-archive
// a default MOBILE_ARCHIVE_SETTINGS.
func testflightOriginProblems(makefile, target string) []string {
	var out []string
	for _, v := range nonEmptyOriginValues(target) {
		if v != "$$origin" {
			out = append(out, fmt.Sprintf("mobile-testflight sets WATCHTOWER_RELAY_ORIGIN to %q: only $$origin read from RELAY_TESTFLIGHT_ORIGIN_FILE is allowed (ask #1156)", v))
		}
	}
	if len(nonEmptyOriginValues(target)) > 0 && !strings.Contains(target, testflightOriginRead) {
		out = append(out, "mobile-testflight sets the origin without reading it through "+testflightOriginRead)
	}
	defs := makeAssignment("RELAY_TESTFLIGHT_ORIGIN_FILE").FindAllStringSubmatch(makefile, -1)
	if len(defs) != 1 || !strings.HasPrefix(strings.TrimSpace(defs[0][1]), "$(HOME)/") {
		out = append(out, "the Makefile must define RELAY_TESTFLIGHT_ORIGIN_FILE once, under $(HOME)/ (a file outside the repo)")
	}
	for _, m := range makeAssignment("MOBILE_ARCHIVE_SETTINGS").FindAllStringSubmatch(makefile, -1) {
		if strings.TrimSpace(m[1]) != "" {
			out = append(out, "the Makefile gives MOBILE_ARCHIVE_SETTINGS a value: only mobile-testflight passes it (ask #1156)")
		}
	}
	return out
}

// nonPlaceholderHosts returns the URL hosts in text that look real: dotted
// names other than example.com placeholders (a bare "host" in usage text is
// not a host).
func nonPlaceholderHosts(text string) []string {
	var out []string
	for _, m := range urlHost.FindAllStringSubmatch(text, -1) {
		h := strings.ToLower(strings.TrimSuffix(m[1], "."))
		if strings.Contains(h, ".") && h != "example.com" && !strings.HasSuffix(h, ".example.com") {
			out = append(out, h)
		}
	}
	return out
}

func TestTestFlightOriginAllowanceRefusesALiteral(t *testing.T) {
	const defs = "RELAY_TESTFLIGHT_ORIGIN_FILE ?= $(HOME)/.config/watchtower/relay-testflight-origin\n"
	const good = "mobile-testflight:\n\t" + testflightOriginRead + ` "$(RELAY_TESTFLIGHT_DARK)") && \` + "\n" +
		"\t$(MAKE) mobile-archive \\\n\t\tMOBILE_ARCHIVE_SETTINGS=\"WATCHTOWER_RELAY_ORIGIN=$$origin\"\n"
	if p := testflightOriginProblems(defs, good); len(p) > 0 {
		t.Errorf("the file-read origin is allowed, got %q", p)
	}
	literal := strings.Replace(good, "$$origin", "https://relay.example.com", 1)
	if len(testflightOriginProblems(defs, literal)) == 0 {
		t.Error("a literal origin on mobile-testflight must be refused")
	}
	unread := "mobile-testflight:\n\t$(MAKE) mobile-archive MOBILE_ARCHIVE_SETTINGS=\"WATCHTOWER_RELAY_ORIGIN=$$origin\"\n"
	if len(testflightOriginProblems(defs, unread)) == 0 {
		t.Error("an origin not read through the script must be refused")
	}
	if len(testflightOriginProblems("RELAY_TESTFLIGHT_ORIGIN_FILE ?= WatchtowerMobile/origin\n", good)) == 0 {
		t.Error("an origin file inside the repo must be refused")
	}
	if p := testflightOriginProblems(defs+good, good); len(p) > 0 {
		t.Errorf("the recipe's own MOBILE_ARCHIVE_SETTINGS argument is not a default, got %q", p)
	}
	if len(testflightOriginProblems(defs+"MOBILE_ARCHIVE_SETTINGS ?= WATCHTOWER_RELAY_ORIGIN=https://relay.example.com\n", good)) == 0 {
		t.Error("a default MOBILE_ARCHIVE_SETTINGS must be refused")
	}
	if len(nonPlaceholderHosts("echo 'https://relay.example.com'")) != 0 || len(nonPlaceholderHosts("https://relay.acme.dev")) != 1 {
		t.Error("nonPlaceholderHosts must pass example.com and catch other hosts")
	}
}

// TestTestFlightOriginScriptValidates runs scripts/testflight-relay-origin.sh
// over temp files: one https origin passes, anything else fails, a missing
// file fails unless the build is dark on purpose.
func TestTestFlightOriginScriptValidates(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}
	script := filepath.Join("..", "..", "scripts", testflightOriginScript)
	dir := t.TempDir()
	run := func(content *string, dark string) (string, error) {
		f := filepath.Join(dir, "origin")
		_ = os.Remove(f)
		if content != nil {
			if err := os.WriteFile(f, []byte(*content), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		out, err := exec.Command("bash", script, f, dark).Output()
		return strings.TrimSpace(string(out)), err
	}
	str := func(s string) *string { return &s }
	for _, c := range []struct {
		in   string
		want string
	}{
		{"https://relay.example.com\n", "https://relay.example.com"},
		{"  https://relay.example.com  \n\n", "https://relay.example.com"},
		{"https://relay.example.com:8443", "https://relay.example.com:8443"},
	} {
		got, err := run(str(c.in), "")
		if err != nil || got != c.want {
			t.Errorf("%q: got %q, %v; want %q", c.in, got, err, c.want)
		}
	}
	for _, bad := range []string{"", "http://relay.example.com", "https://relay.example.com/", "https://relay.example.com/v1",
		"https://relay.example.com?x=1", "https://a.example.com\nhttps://b.example.com", "relay.example.com", "https://"} {
		if got, err := run(str(bad), ""); err == nil {
			t.Errorf("%q: accepted as %q, want a failure", bad, got)
		}
	}
	if _, err := run(nil, ""); err == nil {
		t.Error("a missing file must fail")
	}
	if got, err := run(nil, "1"); err != nil || got != "" {
		t.Errorf("dark: got %q, %v; want no origin and success", got, err)
	}
}

func TestNonEmptyOriginValuesRecognisesAssignments(t *testing.T) {
	for _, c := range []struct {
		in   string
		want int
	}{
		{"WATCHTOWER_RELAY_ORIGIN =", 0},
		{`WATCHTOWER_RELAY_ORIGIN = "";`, 0},
		{`WATCHTOWER_RELAY_ORIGIN = "https://relay.example.com";`, 1},
		{`WATCHTOWER_RELAY_ORIGIN: ""`, 0},
		{`WATCHTOWER_RELAY_ORIGIN: "https://relay.example.com"`, 1},
		{"WATCHTOWER_RELAY_ORIGIN = https://relay.example.com", 1},
		{"\t@make X WATCHTOWER_RELAY_ORIGIN='https://r.example.com'", 1},
		{"WATCHTOWER_RELAY_ORIGIN[config=Release] = https://relay.example.com", 1},
		{"WATCHTOWER_RELAY_ORIGIN[sdk=iphoneos*][config=Release] = https://relay.example.com", 1},
		{"WATCHTOWER_RELAY_ORIGIN[config=Release] =", 0},
		{"// WATCHTOWER_RELAY_ORIGIN = https://relay.example.com", 0},
		{"RELAY_ORIGIN: ${{ vars.RELAY_ORIGIN }}", 0},
	} {
		if got := len(nonEmptyOriginValues(c.in)); got != c.want {
			t.Errorf("%q: %d values, want %d", c.in, got, c.want)
		}
	}
}

func TestScriptFilterCatchesAWrapperThatDoesNotNameThePhone(t *testing.T) {
	if !scriptMayBuildPhone("ship.sh", "#!/bin/sh\nmake mobile-archive WATCHTOWER_RELAY_ORIGIN=https://relay.example.com\n") {
		t.Error("a wrapper calling make mobile-archive must be scanned")
	}
	if !scriptMayBuildPhone("up.sh", "make mobile-testflight") {
		t.Error("a testflight wrapper must be scanned")
	}
	if scriptMayBuildPhone("relay-interop.sh", "xcodebuild archive WATCHTOWER_RELAY_ORIGIN=$ORIGIN") {
		t.Error("the interop stand scripts are excluded")
	}
	if scriptMayBuildPhone("lint.sh", "swiftlint") {
		t.Error("an unrelated script is not scanned")
	}
}
