package watchmanact

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/gitbin"
	"watchtower/internal/tools"
)

// liveRepo is a workbench on a temporary git repository (main committed)
// with one session in its folder.
type liveRepo struct {
	t           *testing.T
	db          *db.DB
	dir         string
	wb, session int64
}

func newLiveRepo(t *testing.T, files map[string]string) *liveRepo {
	t.Helper()
	if _, ok := gitbin.Locate(); !ok {
		t.Skip("git not installed")
	}
	t.Setenv("GIT_CONFIG_GLOBAL", os.DevNull)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	t.Setenv("GIT_AUTHOR_NAME", "t")
	t.Setenv("GIT_AUTHOR_EMAIL", "t@example.com")
	t.Setenv("GIT_COMMITTER_NAME", "t")
	t.Setenv("GIT_COMMITTER_EMAIL", "t@example.com")
	r := &liveRepo{t: t, db: db.OpenTestDB(t), dir: t.TempDir()}
	r.git("init", "-q", "-b", "main")
	for path, text := range files {
		r.write(path, text)
	}
	r.git("add", ".")
	r.git("commit", "-q", "-m", "init")
	var err error
	if r.wb, err = r.db.CreateWorkbench("acme", r.dir); err != nil {
		t.Fatal(err)
	}
	p, err := r.db.GetWorkbench(r.wb)
	if err != nil {
		t.Fatal(err)
	}
	res, err := r.db.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id) VALUES (?, 'claude', 's', ?, 'uuid')`,
		r.wb, p.FolderPath)
	if err != nil {
		t.Fatal(err)
	}
	r.session, _ = res.LastInsertId()
	return r
}

func (r *liveRepo) git(args ...string) {
	r.t.Helper()
	bin, _ := gitbin.Locate()
	cmd := exec.Command(bin, args...)
	cmd.Dir = r.dir
	if out, err := cmd.CombinedOutput(); err != nil {
		r.t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

func (r *liveRepo) write(path, text string) {
	r.t.Helper()
	full := filepath.Join(r.dir, filepath.FromSlash(path))
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		r.t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(text), 0o600); err != nil {
		r.t.Fatal(err)
	}
}

func (r *liveRepo) place() ReviewPlace {
	r.t.Helper()
	place, err := LiveReviewPlace(r.db)(context.Background(), r.wb, r.session)
	if err != nil {
		r.t.Fatal(err)
	}
	return place
}

// swiftTests is a test class with a guard test whose body runs far past
// the diff's context, and an ordinary test after it.
func swiftTests(guardTail, helperTail string) string {
	var b strings.Builder
	b.WriteString("import XCTest\n\nfinal class PanelTests: XCTestCase {\n    func testProj20_Panel() {\n        let a = 1\n")
	for i := range 30 {
		fmt.Fprintf(&b, "        _ = a + %d\n", i)
	}
	b.WriteString("        XCTAssertEqual(a, " + guardTail + ")\n    }\n\n    func testHelperShape() {\n")
	for i := range 10 {
		fmt.Fprintf(&b, "        _ = %d\n", i)
	}
	b.WriteString("        XCTAssertTrue(" + helperTail + ")\n    }\n}\n")
	return b.String()
}

func TestLiveReviewPlace(t *testing.T) {
	t.Run("a real diff, as the finish gate reads it", func(t *testing.T) {
		r := newLiveRepo(t, map[string]string{"x.go": "package x\n\nvar a = 1\n"})
		r.write("x.go", "package x\n\nvar a = 2\n")
		place := r.place()
		if place.Empty || strings.Join(place.Paths, ",") != "x.go" || !strings.Contains(place.Diff, "+var a = 2") {
			t.Fatalf("place = %+v", place)
		}
		if park, why := protectedPlace(place); park != "" {
			t.Fatalf("an ordinary change parks: %s (%s)", park, why)
		}
		p, err := r.db.GetWorkbench(r.wb)
		if err != nil {
			t.Fatal(err)
		}
		snap, err := tools.SnapshotReviewSession(context.Background(), r.db, p, r.session)
		if err != nil {
			t.Fatal(err)
		}
		if place.Round.TreeSHA != snap.Tree || place.Round.BaseSHA != snap.Base || place.Branch != "main" {
			t.Fatalf("place %+v disagrees with the gate's snapshot %+v", place.Round, snap)
		}
	})
	t.Run("no changes", func(t *testing.T) {
		r := newLiveRepo(t, map[string]string{"x.go": "package x\n"})
		if !r.place().Empty {
			t.Fatal("an unchanged folder has nothing to review")
		}
	})
	t.Run("a file over the cap cannot be checked", func(t *testing.T) {
		r := newLiveRepo(t, map[string]string{"x.go": "package x\n"})
		r.write("data/big.txt", strings.Repeat("row\n", 6000))
		place := r.place()
		if park, _ := protectedPlace(place); park != reasonDiffUnchecked {
			t.Fatalf("park = %q, want the diff-too-large park (unchecked %q)", park, place.Unchecked)
		}
	})
	t.Run("a guard test's body edited far from its declaration", func(t *testing.T) {
		r := newLiveRepo(t, map[string]string{"Tests/PanelTests.swift": swiftTests("1", "true")})
		r.write("Tests/PanelTests.swift", swiftTests("2", "true"))
		place := r.place()
		if _, protected := ProtectedChange(place.Paths, place.Diff); protected {
			t.Fatalf("the hunk itself shows no declaration here; the test needs the file read:\n%s", place.Diff)
		}
		if park, why := protectedPlace(place); park != ProtectedReason || !strings.Contains(why, "testProj20_Panel") {
			t.Fatalf("park = %q (%s), want the guard-test park", park, why)
		}
	})
	t.Run("an ordinary test in the same file", func(t *testing.T) {
		r := newLiveRepo(t, map[string]string{"Tests/PanelTests.swift": swiftTests("1", "true")})
		r.write("Tests/PanelTests.swift", swiftTests("1", "false"))
		if park, why := protectedPlace(r.place()); park != "" {
			t.Fatalf("an ordinary test's edit parks: %s (%s)", park, why)
		}
	})
}
