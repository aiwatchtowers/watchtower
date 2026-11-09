package hub

import (
	"os"
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
	for name, text := range texts {
		if vals := nonEmptyOriginValues(text); len(vals) > 0 {
			t.Errorf("%s sets WATCHTOWER_RELAY_ORIGIN to %q: a build with a relay origin must not leave development (launch condition 4, ask #1066)", name, vals)
		}
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
