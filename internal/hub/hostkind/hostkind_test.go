package hostkind

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

const xmlPlist = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
	<key>CFBundleName</key><string>Watchtower</string>
	<key>CFBundleIdentifier</key>
	<string>%s</string>
</dict></plist>`

// fakeProbe is a darwin probe over a temp root standing in for "/": paths
// Detect asks for are read below root.
func fakeProbe(t *testing.T, goos string) (Probe, string) {
	t.Helper()
	root := t.TempDir()
	home := filepath.Join(root, "Users", "owner")
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

func TestDetect_LinuxIsHeadless(t *testing.T) {
	p, root := fakeProbe(t, "linux")
	// Even a darwin-shaped app bundle and MobileHub/ mean nothing off darwin.
	writeAt(t, root, "/Applications/Watchtower.app/Contents/Info.plist", plist(BundleID))
	if err := os.MkdirAll(filepath.Join(root, p.AppSupport, "MobileHub"), 0o700); err != nil {
		t.Fatal(err)
	}
	if k, sig := Detect(p); k != Headless || sig != "" {
		t.Fatalf("linux: %s %q", k, sig)
	}
}

func TestDetect_DarwinAppBundleIsDesktop(t *testing.T) {
	for _, loc := range []string{"/Applications", "~/Applications"} {
		t.Run(loc, func(t *testing.T) {
			p, root := fakeProbe(t, "darwin")
			dir := loc
			if loc == "~/Applications" {
				dir = filepath.Join(p.Home, "Applications")
			}
			writeAt(t, root, filepath.Join(dir, "Watchtower.app/Contents/Info.plist"), plist(BundleID))
			if k, sig := Detect(p); k != Desktop || sig != SignalAppBundle {
				t.Fatalf("%s: %s %q", loc, k, sig)
			}
		})
	}
	t.Run("binary plist", func(t *testing.T) {
		p, root := fakeProbe(t, "darwin")
		raw := append([]byte("bplist00\xd1\x01\x02_\x10\x12CFBundleIdentifier"), 0x5F, 0x10, byte(len(BundleID)))
		raw = append(raw, BundleID...)
		writeAt(t, root, "/Applications/Watchtower.app/Contents/Info.plist", raw)
		if k, sig := Detect(p); k != Desktop || sig != SignalAppBundle {
			t.Fatalf("binary plist: %s %q", k, sig)
		}
	})
}

func TestDetect_DarwinSwiftHubStateIsDesktop(t *testing.T) {
	p, root := fakeProbe(t, "darwin")
	if err := os.MkdirAll(filepath.Join(root, p.AppSupport, "MobileHub"), 0o700); err != nil {
		t.Fatal(err)
	}
	if k, sig := Detect(p); k != Desktop || sig != SignalSwiftHubState {
		t.Fatalf("MobileHub/: %s %q", k, sig)
	}
}

func TestDetect_DarwinCLIOnlyIsHeadless(t *testing.T) {
	p, root := fakeProbe(t, "darwin")
	// The app support folder alone (recordings, the CLI copy) is no signal,
	// nor is a file named MobileHub.
	writeAt(t, root, filepath.Join(p.AppSupport, "MobileHub"), []byte("x"))
	if k, sig := Detect(p); k != Headless || sig != "" {
		t.Fatalf("CLI only: %s %q", k, sig)
	}
}

func TestDetect_ABundleWithAnotherIDIsIgnored(t *testing.T) {
	for _, id := range []string{"com.example.other", BundleID + ".helper", "com.watchtower.desktopx"} {
		p, root := fakeProbe(t, "darwin")
		writeAt(t, root, "/Applications/Watchtower.app/Contents/Info.plist", plist(id))
		if k, _ := Detect(p); k != Headless {
			t.Fatalf("bundle %q read as the app", id)
		}
		raw := append([]byte("bplist00"), 0x5F, 0x10, byte(len(id)))
		writeAt(t, root, "/Applications/Watchtower.app/Contents/Info.plist", append(raw, id...))
		if k, _ := Detect(p); k != Headless {
			t.Fatalf("binary bundle %q read as the app", id)
		}
	}
}
