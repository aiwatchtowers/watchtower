package sessionhost

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type pathsFixture struct {
	Socket []struct {
		BundleID string `json:"bundle_id"`
		TempDir  string `json:"temp_dir"`
		Want     string `json:"want"`
	} `json:"socket"`
	Scope []struct {
		DBPath string `json:"db_path"`
		Want   string `json:"want"`
	} `json:"scope"`
	// Home cases depend on the machine's home folder: the scope of db_path
	// must equal the scope of home + home_suffix.
	Home []struct {
		DBPath     string `json:"db_path"`
		HomeSuffix string `json:"home_suffix"`
	} `json:"home"`
}

// TestPathsFixture pins SocketPath and Scope to testdata/paths.json, which
// the Swift twin (SessionHostPathsFixtureTests) reads too.
func TestPathsFixture(t *testing.T) {
	b, err := os.ReadFile("testdata/paths.json")
	if err != nil {
		t.Fatal(err)
	}
	var f pathsFixture
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	if len(f.Socket) == 0 || len(f.Scope) == 0 || len(f.Home) == 0 {
		t.Fatal("fixture has no cases")
	}
	for _, c := range f.Socket {
		if got := SocketPath(c.BundleID, c.TempDir); got != c.Want {
			t.Errorf("SocketPath(%q, %q) = %q, want %q", c.BundleID, c.TempDir, got, c.Want)
		}
	}
	for _, c := range f.Scope {
		if got := Scope(c.DBPath); got != c.Want {
			t.Errorf("Scope(%q) = %q, want %q", c.DBPath, got, c.Want)
		}
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range f.Home {
		if got, want := Scope(c.DBPath), Scope(home+c.HomeSuffix); got != want {
			t.Errorf("Scope(%q) = %q, want the scope of home%s %q", c.DBPath, got, c.HomeSuffix, want)
		}
		if Scope(c.DBPath) == Scope(filepath.Join(os.TempDir(), c.DBPath)) {
			t.Errorf("Scope(%q) did not expand the home folder", c.DBPath)
		}
	}
}

func TestDefaultSocket(t *testing.T) {
	t.Setenv(SocketEnv, "/tmp/hubtest-x.sock")
	if got := DefaultSocket(); got != "/tmp/hubtest-x.sock" {
		t.Fatalf("DefaultSocket with override = %q", got)
	}
	t.Setenv(SocketEnv, "")
	if got, want := DefaultSocket(), SocketPath(BundleID, os.TempDir()); got != want {
		t.Fatalf("DefaultSocket = %q, want %q", got, want)
	}
}
