package hostkind

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"testing"
	"unicode/utf16"
)

const xmlPlist = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
	<key>CFBundleName</key><string>Watchtower</string>
	<key>Nested</key><dict><key>CFBundleIdentifier</key><string>com.example.nested</string></dict>
	<key>CFBundleIdentifier</key>
	<string>%s</string>
</dict></plist>`

const appPlist = "/Applications/Watchtower.app/Contents/Info.plist"

// fakeProbe is a probe over a temp root standing in for "/": every path
// Detect asks for is read below root.
func fakeProbe(t *testing.T, goos string) (Probe, string) {
	t.Helper()
	root := t.TempDir()
	home := "/Users/owner"
	p := Probe{
		GOOS: goos, Home: home, AppSupport: filepath.Join(home, "Library", "Application Support", "Watchtower"),
		Stat:     func(path string) (os.FileInfo, error) { return os.Stat(filepath.Join(root, path)) },
		ReadFile: func(path string) ([]byte, error) { return os.ReadFile(filepath.Join(root, path)) },
	}
	return p, root
}

func writeAt(t *testing.T, root, path string, body []byte) {
	t.Helper()
	full := filepath.Join(root, path)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, body, 0o644); err != nil {
		t.Fatal(err)
	}
}

func plist(id string) []byte { return []byte(fmt.Sprintf(xmlPlist, id)) }

// bplist encodes a binary plist whose top object is a dict of string keys
// and string values (pairs: key, value, …). utf16 stores every string as
// UTF-16BE (0x6_); every string of 15 or more units takes the int length
// form, with a 2-byte int when wide is set; offsets are 2 bytes wide.
func bplist(utf16Strings, wide bool, pairs ...string) []byte {
	n := len(pairs) / 2
	var objs [][]byte
	dict := []byte{0xD0 | byte(n)}
	for i := 0; i < n; i++ { // keys at refs 1..n, values at n+1..2n
		dict = append(dict, byte(1+i))
	}
	for i := 0; i < n; i++ {
		dict = append(dict, byte(1+n+i))
	}
	objs = append(objs, dict)
	str := func(s string) []byte {
		marker, body, count := byte(0x50), []byte(s), len(s)
		if utf16Strings {
			marker, body = 0x60, nil
			units := utf16.Encode([]rune(s))
			for _, u := range units {
				body = append(body, byte(u>>8), byte(u))
			}
			count = len(units)
		}
		var head []byte
		switch {
		case count < 15:
			head = []byte{marker | byte(count)}
		case wide:
			head = []byte{marker | 0x0F, 0x11, byte(count >> 8), byte(count)}
		default:
			head = []byte{marker | 0x0F, 0x10, byte(count)}
		}
		return append(head, body...)
	}
	for i := 0; i < n; i++ {
		objs = append(objs, str(pairs[2*i]))
	}
	for i := 0; i < n; i++ {
		objs = append(objs, str(pairs[2*i+1]))
	}
	out := []byte("bplist00")
	var offsets []int
	for _, o := range objs {
		offsets = append(offsets, len(out))
		out = append(out, o...)
	}
	table := len(out)
	for _, off := range offsets {
		out = append(out, byte(off>>8), byte(off))
	}
	trailer := make([]byte, 32)
	trailer[6], trailer[7] = 2, 1
	put := func(at int, v int) {
		for i := 0; i < 8; i++ {
			trailer[at+7-i] = byte(v >> (8 * i))
		}
	}
	put(8, len(objs))
	put(16, 0)
	put(24, table)
	return append(out, trailer...)
}

// buildAppPlist is the Info.plist scripts/build-app.sh writes, taken from
// its heredoc with the variables filled in.
func buildAppPlist(t *testing.T, bundleID string) []byte {
	t.Helper()
	raw, err := os.ReadFile("../../../scripts/build-app.sh")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?s)cat > "\$APP_BUNDLE/Contents/Info.plist" << PLIST\n(.*?)\nPLIST\n`).FindSubmatch(raw)
	if m == nil {
		t.Fatal("the Info.plist heredoc is gone from scripts/build-app.sh")
	}
	body := strings.NewReplacer("$BUNDLE_ID", bundleID, "$VERSION", "1.2.3").Replace(string(m[1]))
	if strings.Contains(body, "$") {
		t.Fatalf("an unfilled variable in the Info.plist heredoc: %s", body)
	}
	return []byte(body)
}

func TestDetect_LinuxIsHeadless(t *testing.T) {
	p, root := fakeProbe(t, "linux")
	// Even a darwin-shaped app bundle and MobileHub/ mean nothing off darwin.
	writeAt(t, root, appPlist, plist(BundleID))
	if err := os.MkdirAll(filepath.Join(root, p.AppSupport, "MobileHub"), 0o700); err != nil {
		t.Fatal(err)
	}
	if k, sig := Detect(p); k != Headless || sig != "" {
		t.Fatalf("linux: %s %q", k, sig)
	}
}

func TestDetect_DarwinAppBundleIsDesktop(t *testing.T) {
	for _, loc := range []string{"/Applications", "/Users/owner/Applications"} {
		t.Run(loc, func(t *testing.T) {
			p, root := fakeProbe(t, "darwin")
			writeAt(t, root, filepath.Join(loc, "Watchtower.app/Contents/Info.plist"), plist(BundleID))
			if k, sig := Detect(p); k != Desktop || sig != SignalAppBundle {
				t.Fatalf("%s: %s %q", loc, k, sig)
			}
		})
	}
	for name, raw := range map[string][]byte{
		"build-app.sh's plist": buildAppPlist(t, BundleID),
		"binary ascii":         bplist(false, false, "CFBundleName", "Watchtower", "CFBundleIdentifier", BundleID),
		"binary ascii wide":    bplist(false, true, "CFBundleIdentifier", BundleID),
		"binary utf-16":        bplist(true, false, "CFBundleName", "Watchtower", "CFBundleIdentifier", BundleID),
		"binary utf-16 wide":   bplist(true, true, "CFBundleIdentifier", BundleID),
	} {
		t.Run(name, func(t *testing.T) {
			p, root := fakeProbe(t, "darwin")
			writeAt(t, root, appPlist, raw)
			if k, sig := Detect(p); k != Desktop || sig != SignalAppBundle {
				t.Fatalf("%s: %s %q", name, k, sig)
			}
		})
	}
}

// TestDetect_AnUnreadableAppBundleIsDesktop: Detect fails closed — an app
// whose Info.plist is missing, unreadable, malformed or names no bundle id
// reads as the app.
func TestDetect_AnUnreadableAppBundleIsDesktop(t *testing.T) {
	cases := map[string]func(t *testing.T, p *Probe, root string){
		"no Info.plist": func(t *testing.T, _ *Probe, root string) {
			if err := os.MkdirAll(filepath.Join(root, "/Applications/Watchtower.app/Contents"), 0o755); err != nil {
				t.Fatal(err)
			}
		},
		"unreadable": func(_ *testing.T, p *Probe, _ string) {
			p.ReadFile = func(string) ([]byte, error) { return nil, syscall.EACCES }
		},
		"app dir unstat-able": func(_ *testing.T, p *Probe, _ string) {
			p.Stat = func(string) (os.FileInfo, error) { return nil, syscall.EACCES }
		},
		"malformed xml": func(t *testing.T, _ *Probe, root string) { writeAt(t, root, appPlist, []byte("<plist><dict><key>")) },
		"no bundle id": func(t *testing.T, _ *Probe, root string) {
			writeAt(t, root, appPlist, []byte("<plist><dict></dict></plist>"))
		},
		"not a plist": func(t *testing.T, _ *Probe, root string) { writeAt(t, root, appPlist, []byte("<html></html>")) },
		"key, no string": func(t *testing.T, _ *Probe, root string) {
			writeAt(t, root, appPlist, []byte("<plist><dict><key>CFBundleIdentifier</key><integer>1</integer></dict></plist>"))
		},
		"truncated binary": func(t *testing.T, _ *Probe, root string) {
			raw := bplist(false, false, "CFBundleIdentifier", BundleID)
			writeAt(t, root, appPlist, raw[:len(raw)-40])
		},
		"binary garbage trailer": func(t *testing.T, _ *Probe, root string) {
			raw := bplist(false, false, "CFBundleIdentifier", BundleID)
			for i := len(raw) - 8; i < len(raw); i++ {
				raw[i] = 0xFF
			}
			writeAt(t, root, appPlist, raw)
		},
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			p, root := fakeProbe(t, "darwin")
			setup(t, &p, root)
			if k, sig := Detect(p); k != Desktop || sig != SignalAppBundle {
				t.Fatalf("%s: %s %q", name, k, sig)
			}
		})
	}
}

func TestDetect_DarwinSwiftHubStateIsDesktop(t *testing.T) {
	p, root := fakeProbe(t, "darwin")
	if err := os.MkdirAll(filepath.Join(root, p.AppSupport, "MobileHub"), 0o700); err != nil {
		t.Fatal(err)
	}
	if k, sig := Detect(p); k != Desktop || sig != SignalSwiftHubState {
		t.Fatalf("MobileHub/: %s %q", k, sig)
	}

	// A MobileHub/ whose existence cannot be checked reads as there.
	p, _ = fakeProbe(t, "darwin")
	stat := p.Stat
	p.Stat = func(path string) (os.FileInfo, error) {
		if strings.HasSuffix(path, "MobileHub") {
			return nil, syscall.EACCES
		}
		return stat(path)
	}
	if k, sig := Detect(p); k != Desktop || sig != SignalSwiftHubState {
		t.Fatalf("MobileHub/ unstat-able: %s %q", k, sig)
	}
}

func TestDetect_DarwinCLIOnlyIsHeadless(t *testing.T) {
	p, root := fakeProbe(t, "darwin")
	// The app support folder alone (recordings, the CLI copy) is no signal,
	// nor is a file named MobileHub, nor an app support path through a file.
	writeAt(t, root, filepath.Join(p.AppSupport, "MobileHub"), []byte("x"))
	if k, sig := Detect(p); k != Headless || sig != "" {
		t.Fatalf("CLI only: %s %q", k, sig)
	}
	p, root = fakeProbe(t, "darwin")
	writeAt(t, root, p.AppSupport, []byte("a file"))
	if k, _ := Detect(p); k != Headless {
		t.Fatal("ENOTDIR read as the Swift hub's state")
	}
}

func TestDetect_ABundleWithAnotherIDIsIgnored(t *testing.T) {
	for _, id := range []string{"com.example.other", BundleID + ".helper", "com.watchtower.desktopx", "com.example.short"} {
		for name, raw := range map[string][]byte{
			"xml":           plist(id),
			"build-app.sh":  buildAppPlist(t, id),
			"binary":        bplist(false, false, "CFBundleIdentifier", id, "Other", BundleID),
			"binary utf-16": bplist(true, true, "CFBundleIdentifier", id),
		} {
			p, root := fakeProbe(t, "darwin")
			writeAt(t, root, appPlist, raw)
			if k, _ := Detect(p); k != Headless {
				t.Fatalf("%s bundle %q read as the app", name, id)
			}
		}
	}
}

func FuzzPlistBundleID(f *testing.F) {
	f.Add(bplist(false, false, "CFBundleIdentifier", BundleID))
	f.Add(bplist(true, true, "CFBundleName", "Watchtower", "CFBundleIdentifier", BundleID))
	f.Add(plist(BundleID))
	f.Fuzz(func(_ *testing.T, raw []byte) { _, _ = plistBundleID(raw) })
}

func TestPlistBundleIDReadsOnlyTheTopDict(t *testing.T) {
	id, err := plistBundleID(plist("com.example.top"))
	if err != nil || id != "com.example.top" {
		t.Fatalf("%q %v", id, err)
	}
	if _, err := plistBundleID(bplist(false, false, "Other", BundleID)); !errors.Is(err, errPlist) {
		t.Fatalf("a binary plist with no bundle id: %v", err)
	}
}
