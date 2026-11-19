package aiconsent

import (
	"bytes"
	"context"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
)

func envOf(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestOrigin_ContextBeatsProcess(t *testing.T) {
	resetForTest(t)
	InitProcess("daemon", envOf(nil))
	if o, _ := OriginOf(context.Background()); o != OriginBackground {
		t.Fatalf("daemon default = %v, want background", o)
	}
	if o, admitted := OriginOf(WithOwnerStarted(context.Background())); o != OriginOwner || admitted {
		t.Fatalf("owner mark in the daemon = (%v, %v), want owner", o, admitted)
	}
	// The latest mark wins.
	ctx := WithOwnerStarted(WithAdmitted(context.Background(), "phase:digests"))
	if o, _ := OriginOf(ctx); o != OriginOwner {
		t.Fatalf("owner mark over admitted = %v, want owner", o)
	}
	if o, admitted := OriginOf(WithAdmitted(context.Background(), "phase:digests")); o != OriginBackground || !admitted {
		t.Fatalf("admitted mark = (%v, %v), want background admitted", o, admitted)
	}
}

func TestOrigin_EnvMarksBackground(t *testing.T) {
	resetForTest(t)
	InitProcess("cli", envOf(map[string]string{EnvOrigin: "background"}))
	if o, admitted := OriginOf(context.Background()); o != OriginBackground || admitted {
		t.Fatalf("got (%v, %v), want background unadmitted", o, admitted)
	}
	InitProcess("cli", envOf(map[string]string{EnvOrigin: "background", EnvAdmitted: "run:7"}))
	if o, admitted := OriginOf(context.Background()); o != OriginBackground || !admitted {
		t.Fatalf("got (%v, %v), want background admitted", o, admitted)
	}
	InitProcess("cli", envOf(nil))
	if o, _ := OriginOf(context.Background()); o != OriginOwner {
		t.Fatalf("no env = %v, want owner", o)
	}
}

func TestOrigin_AutomationMarkerTakesRunTrigger(t *testing.T) {
	for _, c := range []struct {
		name    string
		trigger string
		err     error
		want    Origin
	}{
		{"manual", "manual", nil, OriginOwner},
		{"schedule", "schedule", nil, OriginBackground},
		{"lookup error", "", errors.New("db gone"), OriginBackground},
	} {
		t.Run(c.name, func(t *testing.T) {
			resetForTest(t)
			lines := captureLog(t)
			lookups := 0
			var gotID int64
			SetRunTriggerLookup(func(id int64) (string, error) {
				lookups++
				gotID = id
				return c.trigger, c.err
			})
			InitProcess("mcp", envOf(map[string]string{RunMarkerEnv: "7"}))
			for range 2 {
				if o, admitted := OriginOf(context.Background()); o != c.want || admitted {
					t.Fatalf("got (%v, %v), want %v unadmitted", o, admitted, c.want)
				}
			}
			// A resolved trigger is read once; a lookup error is retried.
			wantLookups, wantLines := 1, 0
			if c.err != nil {
				wantLookups, wantLines = 2, 2
			}
			if lookups != wantLookups || gotID != 7 {
				t.Fatalf("lookups = %d for run %d, want %d for run 7", lookups, gotID, wantLookups)
			}
			if len(*lines) != wantLines {
				t.Fatalf("logged %q, want %d lines", *lines, wantLines)
			}
		})
	}
}

// A caller whose lookup fails after another caller resolved the marker
// returns the resolved origin, not background.
func TestOrigin_FailedLookupReturnsAResolvedMark(t *testing.T) {
	resetForTest(t)
	captureLog(t)
	entered, release := make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	SetRunTriggerLookup(func(int64) (string, error) {
		if calls.Add(1) == 1 {
			close(entered)
			<-release
			return "", errors.New("db busy")
		}
		return "manual", nil
	})
	InitProcess("mcp", envOf(map[string]string{RunMarkerEnv: "7"}))
	slow := make(chan Origin)
	go func() {
		o, _ := OriginOf(context.Background())
		slow <- o
	}()
	<-entered
	if o, _ := OriginOf(context.Background()); o != OriginOwner {
		t.Fatalf("the resolving caller got %v, want owner", o)
	}
	close(release)
	if o := <-slow; o != OriginOwner {
		t.Fatalf("the caller whose lookup failed got %v, want the resolved owner", o)
	}
}

func TestOrigin_AutomationMarkerFailsClosed(t *testing.T) {
	resetForTest(t)
	captureLog(t)
	InitProcess("mcp", envOf(map[string]string{RunMarkerEnv: "7"}))
	if o, _ := OriginOf(context.Background()); o != OriginBackground {
		t.Fatalf("no lookup wired = %v, want background", o)
	}
	InitProcess("mcp", envOf(map[string]string{RunMarkerEnv: "not-a-number"}))
	SetRunTriggerLookup(func(int64) (string, error) { return "manual", nil })
	if o, _ := OriginOf(context.Background()); o != OriginBackground {
		t.Fatalf("an unparsable run id = %v, want background", o)
	}
}

func TestBackgroundTrigger(t *testing.T) {
	for _, tr := range []string{"schedule", "catch_up", "event", "sync"} {
		if !BackgroundTrigger(tr) {
			t.Errorf("%q must be background", tr)
		}
	}
	for _, tr := range []string{"manual", "button", "dry_run", "reply", ""} {
		if BackgroundTrigger(tr) {
			t.Errorf("%q must not be background", tr)
		}
	}
}

func TestCheck_AdmittedBackgroundPasses(t *testing.T) {
	resetForTest(t)
	InitProcess("daemon", envOf(nil))
	if err := CheckWith(WithAdmitted(context.Background(), "phase:digests"), pausedReader); err != nil {
		t.Fatalf("an admitted unit must finish, got %v", err)
	}
	InitProcess("cli", envOf(map[string]string{EnvOrigin: "background", EnvAdmitted: "run:7"}))
	if err := CheckWith(context.Background(), pausedReader); err != nil {
		t.Fatalf("an admitted child must pass, got %v", err)
	}
	InitProcess("cli", envOf(map[string]string{EnvOrigin: "background"}))
	if err := CheckWith(context.Background(), pausedReader); !errors.Is(err, ErrPaused) {
		t.Fatalf("an unadmitted background child must be refused, got %v", err)
	}
}

func TestChildEnv_BackgroundAndAdmitted(t *testing.T) {
	resetForTest(t)
	InitProcess("cli", envOf(nil))
	if env := ChildEnv(context.Background()); env != nil {
		t.Fatalf("owner ctx env = %q, want nil", env)
	}
	InitProcess("daemon", envOf(nil))
	if got, want := ChildEnv(context.Background()), []string{EnvOrigin + "=background"}; !slices.Equal(got, want) {
		t.Fatalf("daemon ctx env = %q, want %q", got, want)
	}
	got := ChildEnv(WithAdmitted(context.Background(), "phase:digests"))
	want := []string{EnvOrigin + "=background", EnvAdmitted + "=phase:digests"}
	if !slices.Equal(got, want) {
		t.Fatalf("admitted ctx env = %q, want %q", got, want)
	}
	// An admitted child passes its admission on to its own children.
	InitProcess("cli", envOf(map[string]string{EnvOrigin: "background", EnvAdmitted: "run:7"}))
	want = []string{EnvOrigin + "=background", EnvAdmitted + "=run:7"}
	if got := ChildEnv(context.Background()); !slices.Equal(got, want) {
		t.Fatalf("admitted process env = %q, want %q", got, want)
	}
}

// TestChildEnv_OwnerChildOfBackgroundProcess: a process started with
// EnvOrigin=background that serves an owner request builds its child's env as
// append(OwnerEnv(os.Environ()), ChildEnv(ctx)...); the inherited origin is
// stripped.
func TestChildEnv_OwnerChildOfBackgroundProcess(t *testing.T) {
	resetForTest(t)
	parent := []string{"PATH=/bin", EnvOrigin + "=background", EnvAdmitted + "=run:7"}
	InitProcess("cli", envOf(map[string]string{EnvOrigin: "background", EnvAdmitted: "run:7"}))
	got := append(OwnerEnv(parent), ChildEnv(WithOwnerStarted(context.Background()))...)
	if want := []string{"PATH=/bin"}; !slices.Equal(got, want) {
		t.Fatalf("owner child env = %q, want %q", got, want)
	}
	got = append(OwnerEnv(parent), ChildEnv(WithAdmitted(context.Background(), "phase:digests"))...)
	want := []string{"PATH=/bin", EnvOrigin + "=background", EnvAdmitted + "=phase:digests"}
	if !slices.Equal(got, want) {
		t.Fatalf("background child env = %q, want %q", got, want)
	}
}

func TestOwnerEnv_StripsOrigin(t *testing.T) {
	in := []string{"PATH=/bin", EnvOrigin + "=background", EnvAdmitted + "=run:7", "HOME=/h", RunMarkerEnv + "=7"}
	got := OwnerEnv(in)
	want := []string{"PATH=/bin", "HOME=/h", RunMarkerEnv + "=7"}
	if !slices.Equal(got, want) {
		t.Fatalf("got %q, want %q", got, want)
	}
	if len(in) != 5 {
		t.Fatal("OwnerEnv must not modify its input")
	}
}

// TestOverrideHookOnlyInTests: SetCurrentOverrideForTest makes every consent
// read say "allowed", so no production file may reference it (a call, a
// method value, anything) or import aiconsenttest. Only test files and the
// aiconsenttest helper do.
func TestOverrideHookOnlyInTests(t *testing.T) {
	root := repoRoot(t)
	allowed := filepath.Join(root, "internal", "aiconsent", "aiconsenttest")
	skipDirs := map[string]bool{"WatchtowerDesktop": true, "WatchtowerKit": true, "WatchtowerMobile": true, "docs": true, "node_modules": true, "vendor": true, "testdata": true}
	const (
		hook       = "SetCurrentOverrideForTest"
		helperPath = "watchtower/internal/aiconsent/aiconsenttest"
	)
	var offenders []string
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if path != root && (strings.HasPrefix(d.Name(), ".") || skipDirs[d.Name()]) {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") || filepath.Dir(path) == allowed {
			return nil
		}
		src, err := os.ReadFile(path) //nolint:gosec // G122: a test walking its own checkout
		if err != nil || (!bytes.Contains(src, []byte(hook)) && !bytes.Contains(src, []byte(helperPath))) {
			return err
		}
		f, err := parser.ParseFile(token.NewFileSet(), path, src, parser.SkipObjectResolution)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		for _, imp := range f.Imports {
			if ip, err := strconv.Unquote(imp.Path.Value); err == nil && ip == helperPath {
				offenders = append(offenders, rel+" imports aiconsenttest")
			}
		}
		ast.Inspect(f, func(n ast.Node) bool {
			if id, ok := n.(*ast.Ident); ok && id.Name == hook && !isDecl(f, id) {
				offenders = append(offenders, rel+" references "+hook)
			}
			return true
		})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(offenders) > 0 {
		t.Fatalf("the consent override is reachable from production code: %v", offenders)
	}
}

// isDecl reports whether id is the name of a top-level function declaration.
func isDecl(f *ast.File, id *ast.Ident) bool {
	for _, d := range f.Decls {
		if fd, ok := d.(*ast.FuncDecl); ok && fd.Name == id {
			return true
		}
	}
	return false
}

func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("go.mod not found")
		}
		dir = parent
	}
}
