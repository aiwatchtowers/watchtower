package sessioncleanup

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func mkdirs(t *testing.T, root string, rels ...string) {
	t.Helper()
	for _, r := range rels {
		if err := os.MkdirAll(filepath.Join(root, r), 0o755); err != nil {
			t.Fatal(err)
		}
	}
}

func TestBundles_SkipsNodeModulesAndGitAndDepth(t *testing.T) {
	root := t.TempDir()
	mkdirs(t, root,
		"Top.app/Contents/Inner.app", // listed once, not descended
		".build/debug/Build.app",     // depth 3
		"a/b/c/d/e/Deep.app",         // depth 6: listed
		"a/b/c/d/e/f/TooDeep.app",    // depth 7: skipped
		"node_modules/pkg/Dep.app",   // skipped
		".git/worktrees/x/Git.app",   // skipped
		"plain/notanapp",
	)
	outside := t.TempDir()
	mkdirs(t, outside, "Linked.app")
	if err := os.Symlink(filepath.Join(outside, "Linked.app"), filepath.Join(root, "Via.app")); err != nil {
		t.Fatal(err)
	}
	got := SystemLaunchServices{}.Bundles(root)
	want := []string{
		filepath.Join(root, ".build/debug/Build.app"),
		filepath.Join(root, "Top.app"),
		filepath.Join(root, "a/b/c/d/e/Deep.app"),
	}
	slices.Sort(got)
	if !slices.Equal(got, want) {
		t.Fatalf("Bundles = %q, want %q", got, want)
	}
}

const lsregDumpFixture = `--------------------------------------------------------------------------------
bundle id:                  1234
path:                       /Applications/Foo.app (0x7de0)
name:                       Foo
--------------------------------------------------------------------------------
path:                       /Users/example/Build/Products/Debug/My App.app (0xa43c)
path:                       /Applications/Foo.app (0x7de0)
path:                       /Library/Some.framework (0x1)
container path:             /Applications/Ignored.app
path:                       /Applications/NoSuffixId.app
`

func TestLsregDumpParse_Fixture(t *testing.T) {
	got, err := parseLsregDump([]byte(lsregDumpFixture))
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"/Applications/Foo.app", "/Users/example/Build/Products/Debug/My App.app", "/Applications/NoSuffixId.app"}
	if !slices.Equal(got, want) {
		t.Fatalf("parseLsregDump = %q, want %q", got, want)
	}
}

func TestStale_ListsOnlyGoneBundlesUnderTheFolder(t *testing.T) {
	folder := t.TempDir()
	canon := canonicalPath(folder)
	mkdirs(t, folder, "wt/Still.app")
	dump := strings.Join([]string{
		"path:   " + filepath.Join(canon, "wt/Still.app") + " (0x1)",
		"path:   " + filepath.Join(canon, "gone/Gone.app") + " (0x2)",
		"path:   " + filepath.Join(folder, "gone2/Gone2.app") + " (0x3)",
		"path:   /Applications/Elsewhere-gone-535.app (0x4)",
	}, "\n")
	cmds := &fakeCmds{out: map[string]string{lsregisterBinary: dump}}
	got, err := SystemLaunchServices{run: cmds.run}.Stale(context.Background(), folder)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{filepath.Join(canon, "gone/Gone.app"), filepath.Join(folder, "gone2/Gone2.app")}
	if !slices.Equal(got, want) {
		t.Fatalf("Stale = %q, want %q", got, want)
	}
	if !slices.Equal(cmds.calls[0], []string{lsregisterBinary, "-dump"}) {
		t.Fatalf("ran %q", cmds.calls[0])
	}
}

func TestUnregister_UsesTheFixedBinaryAndTheCanonicalPath(t *testing.T) {
	if !strings.HasPrefix(lsregisterBinary, "/System/Library/") {
		t.Fatalf("lsregister path %q is not the fixed system path", lsregisterBinary)
	}
	dir := t.TempDir()
	bundle := filepath.Join(dir, "deleted", "Gone.app") // never existed: the deleted case
	cmds := &fakeCmds{}
	if err := (SystemLaunchServices{run: cmds.run}).Unregister(context.Background(), bundle); err != nil {
		t.Fatal(err)
	}
	resolved, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{lsregisterBinary, "-u", filepath.Join(resolved, "deleted", "Gone.app")}
	if !slices.Equal(cmds.calls[0], want) {
		t.Fatalf("ran %q, want %q", cmds.calls[0], want)
	}
	failing := &fakeCmds{fail: map[string]error{lsregisterBinary: os.ErrPermission}}
	if err := (SystemLaunchServices{run: failing.run}).Unregister(context.Background(), bundle); err == nil {
		t.Fatal("a failing lsregister returned nil")
	}
}
