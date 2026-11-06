package builtin

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
)

// withDefaultFolder gives built-in id another default folder for the test
// (the shipped built-ins default to the root, but Needs approval).
func withDefaultFolder(t *testing.T, id, slug string) {
	t.Helper()
	for i := range registry {
		if registry[i].ID == id {
			old := registry[i].DefaultFolder
			registry[i].DefaultFolder = slug
			t.Cleanup(func() { registry[i].DefaultFolder = old })
			return
		}
	}
	t.Fatalf("no built-in %q", id)
}

// captureLog collects logf's lines for the test.
func captureLog(t *testing.T) func() []string {
	t.Helper()
	var (
		mu    sync.Mutex
		lines []string
	)
	old := logf
	logf = func(format string, args ...any) {
		mu.Lock()
		defer mu.Unlock()
		lines = append(lines, fmt.Sprintf(format, args...))
	}
	t.Cleanup(func() { logf = old })
	return func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), lines...)
	}
}

// routeOf is the folder slug automation id is routed to ("" = no route).
func (f *fixture) routeOf(t *testing.T, id int64) string {
	t.Helper()
	_, folders, routes, err := f.d.InboxFolderTree(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	folderID, ok := routes[id]
	if !ok {
		return ""
	}
	for _, folder := range folders {
		if folder.ID == folderID {
			return folder.Slug
		}
	}
	t.Fatalf("route of %d names folder %d, not in the tree", id, folderID)
	return ""
}

// nonRootDefaults counts the built-ins whose default folder is not the
// root: a first sync seeds one route, one revision bump, for each.
func nonRootDefaults() int64 {
	var n int64
	for _, e := range All() {
		if e.DefaultFolder != RootFolder {
			n++
		}
	}
	return n
}

// linesOf is the lines that name built-in id.
func linesOf(lines []string, id string) []string {
	var out []string
	for _, l := range lines {
		if strings.Contains(l, "built-in "+id+":") {
			out = append(out, l)
		}
	}
	return out
}

func (f *fixture) folderRevision(t *testing.T) int64 {
	t.Helper()
	rev, _, _, err := f.d.InboxFolderTree(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return rev
}

// A built-in whose default folder is not the root gets that route at its
// first sync, once; a route the owner set later is kept by every sync after.
func TestBuiltinIndex_RouteSeededOnceAndOwnerMoveKept(t *testing.T) {
	f := newFixture(t)
	withDefaultFolder(t, mbID, "needs-approval")
	rev := f.folderRevision(t)

	f.sync(t)
	a := f.row(t)
	if got := f.routeOf(t, a.ID); got != "needs-approval" {
		t.Fatalf("route after the first sync = %q, want needs-approval", got)
	}
	seeded := rev + nonRootDefaults()
	if got := f.folderRevision(t); got != seeded {
		t.Errorf("revision = %d, want %d (each seed bumps it once)", got, seeded)
	}

	f.sync(t)
	if got := f.folderRevision(t); got != seeded {
		t.Errorf("revision after a second sync = %d, want %d (seeded once)", got, seeded)
	}

	// The owner moves it to the root (an explicit route row).
	if _, err := f.d.Exec(`UPDATE inbox_folder_routes SET folder_id = (SELECT id FROM inbox_folders WHERE kind = 'root')
		WHERE automation_id = ?`, a.ID); err != nil {
		t.Fatal(err)
	}
	f.sync(t)
	if got := f.routeOf(t, a.ID); got != RootFolder {
		t.Errorf("route after the owner's move and a sync = %q, want %q", got, RootFolder)
	}
}

// A built-in that defaults to the root gets no route; Needs approval gets
// its own folder's. The revision moves once per seeded route.
func TestBuiltinIndex_RootDefaultSeedsNoRoute(t *testing.T) {
	f := newFixture(t)
	rev := f.folderRevision(t)
	f.sync(t)
	for _, e := range All() {
		want := ""
		if e.DefaultFolder != RootFolder {
			want = e.DefaultFolder
		}
		if got := f.routeOf(t, f.rowOf(t, e.ID).ID); got != want {
			t.Errorf("%s: route %q, want %q", e.ID, got, want)
		}
	}
	if got := f.routeOf(t, f.rowOf(t, NeedsApprovalID).ID); got != NeedsApprovalID {
		t.Errorf("needs-approval: route %q, want its own folder", got)
	}
	if got, want := f.folderRevision(t), rev+nonRootDefaults(); got != want {
		t.Errorf("revision = %d, want %d", got, want)
	}
}

// A route seed that fails is logged, not the sync's: the built-in is still
// indexed and confirmed, and the next sync seeds the route.
func TestBuiltinIndex_RouteSeedFailureKeepsBuiltin(t *testing.T) {
	f := newFixture(t)
	withDefaultFolder(t, mbID, "needs-approval")
	logs := captureLog(t)
	if _, err := f.d.Exec(`CREATE TRIGGER test_refuse_route BEFORE INSERT ON inbox_folder_routes
		BEGIN SELECT RAISE(ABORT, 'route refused'); END`); err != nil {
		t.Fatal(err)
	}

	rep, err := Sync(context.Background(), f.d, f.ws, f.cfg, f.clock.Now())
	if err != nil {
		t.Fatalf("Sync: %v; a failed seed is not the sync's error", err)
	}
	if _, ok := rep.Errors[mbID]; ok {
		t.Errorf("report errors = %v; a failed seed is only logged", rep.Errors)
	}
	a := f.row(t)
	if !a.Confirmed() || a.ParseError != "" {
		t.Errorf("row = %+v; want indexed and confirmed", a)
	}
	if got := f.routeOf(t, a.ID); got != "" {
		t.Errorf("route = %q, want none after the failed seed", got)
	}
	lines := linesOf(logs(), mbID)
	if len(lines) != 1 || !strings.Contains(lines[0], "built-in morning-brief: seeding its inbox folder route") ||
		!strings.Contains(lines[0], "route refused") {
		t.Errorf("logged = %q", lines)
	}

	if _, err := f.d.Exec(`DROP TRIGGER test_refuse_route`); err != nil {
		t.Fatal(err)
	}
	f.sync(t)
	if got := f.routeOf(t, a.ID); got != "needs-approval" {
		t.Errorf("route after the next sync = %q, want needs-approval", got)
	}
	if got := len(linesOf(logs(), mbID)); got != 1 {
		t.Errorf("logged %d lines, want only the failure's", got)
	}
}

// Every built-in names a default folder that exists in a fresh database.
func TestRegistry_DefaultFolderExists(t *testing.T) {
	f := newFixture(t)
	_, folders, _, err := f.d.InboxFolderTree(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	slugs := map[string]bool{}
	for _, folder := range folders {
		slugs[folder.Slug] = true
	}
	for _, e := range All() {
		if e.DefaultFolder == "" || !slugs[e.DefaultFolder] {
			t.Errorf("%s: default folder %q is not a folder", e.ID, e.DefaultFolder)
		}
	}
}
