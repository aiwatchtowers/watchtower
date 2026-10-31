package sources

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
)

// Go twins of WorkbenchSliceTests (the git refresher's tests move with the
// refresher).

const home = "/Users/acme"

func workbenchSrc(d *db.DB, git func(int64) (GitSnapshot, bool)) hubslices.Source {
	return Workbench(d, WorkbenchOptions{Home: home, GitStatus: git})
}

func TestWorkbenchMatchesKitFixtureKeys(t *testing.T) {
	d := db.OpenTestDB(t)
	id := insertWorkbench(t, d, "Acme", home+"/Projects/acme")
	exec(t, d, `UPDATE projects SET description = ? WHERE id = ?`, strings.Repeat("d", 1001), id)
	insertSession(t, d, id, sessionSeed{})
	p := only(t, payloads(t, workbenchSrc(d, func(int64) (GitSnapshot, bool) {
		return GitSnapshot{Branch: "feature/acme-export", Changes: 3}, true
	})))

	assertWireShape(t, p, kitFixture(t, "workbench/workbench.json"),
		"name_clipped", "description_clipped", "folder_display_clipped", "branch_clipped",
		"last_session_activity", "targets_more", "automations")
	if p["description_clipped"] != true || runes(p["description"]) != 1000 {
		t.Errorf("description = %d runes, clipped %v", runes(p["description"]), p["description_clipped"])
	}
	if _, ok := p["name_clipped"]; ok {
		t.Error("an unclipped field carries no flag key")
	}
	if _, ok := p["targets_more"]; ok {
		t.Error("a board inside its window carries no targets_more")
	}
	if p["branch"] != "feature/acme-export" || num(p["changes"]) != 3 {
		t.Errorf("branch %v changes %v", p["branch"], p["changes"])
	}
	if p["folder_display"] != "~/Projects/acme" {
		t.Errorf("folder_display = %v", p["folder_display"])
	}
}

func insertAutomation(t *testing.T, d *db.DB, slug, name, trigger, spec string, workbench *int64, removed *string) int64 {
	t.Helper()
	scope, path := "personal", "/tmp/acme/automations/"+slug+".md"
	if workbench != nil {
		scope, path = "workbench", fmt.Sprintf("/tmp/acme/.watchtower/automations/%d-%s.md", *workbench, slug)
	}
	return lastID(t, exec(t, d, `INSERT INTO automations (slug, scope, project_id, path, name, trigger_kind, trigger_spec,
    approval_hash, confirmed_hash, enabled, removed_at)
VALUES (?, ?, ?, ?, ?, ?, ?, 'h1', 'h1', 1, ?)`, slug, scope, workbench, path, name, trigger, spec, removed))
}

// Ask #692: each workbench carries its own recipes in quick run's order
// (manual and button first), resolved and in the Kit's shape; personal and
// removed recipes are left out, and a workbench with none has no key.
func TestWorkbenchAutomationsArePublishedPerWorkbench(t *testing.T) {
	d := db.OpenTestDB(t)
	acme := insertWorkbench(t, d, "Acme", home+"/Projects/acme")
	notes := insertWorkbench(t, d, "Notes", home+"/Projects/notes")
	insertAutomation(t, d, "nightly", "Nightly triage", "schedule", `{"schedule":"0 3 * * *"}`, &acme, nil)
	release := insertAutomation(t, d, "release", "Release notes", "button", `{"button":{"label":"Release","confirm":true}}`, &acme, nil)
	exec(t, d, `INSERT INTO automation_runs (automation_id, trigger, status, queued_at, started_at, finished_at)
VALUES (?, 'button', 'succeeded', '2026-10-01T09:00:00Z', '2026-10-01T09:00:01Z', '2023-11-14T22:13:20Z')`, release)
	insertAutomation(t, d, "off", "Old", "manual", `{"manual":true}`, &acme, ptr("2026-01-01T00:00:00Z"))
	insertAutomation(t, d, "mine", "Personal", "manual", `{"manual":true}`, nil, nil)

	all := payloads(t, workbenchSrc(d, nil))
	if _, ok := all[notes]["automations"]; ok {
		t.Error("a workbench with no recipe has no automations key")
	}
	list, _ := all[acme]["automations"].([]any)
	if len(list) != 2 {
		t.Fatalf("automations = %v", all[acme]["automations"])
	}
	first, second := list[0].(map[string]any), list[1].(map[string]any)
	if first["name"] != "Release notes" || second["name"] != "Nightly triage" {
		t.Errorf("order = %v, %v", first["name"], second["name"])
	}
	fixture := kitFixture(t, "workbench/workbench.json")["automations"].([]any)
	assertWireShape(t, first, fixture[0].(map[string]any))
	if first["kind"] != "button" || first["asks_first"] != true || first["state"] != "runnable" ||
		first["last_run_status"] != "succeeded" || num(first["last_run_at"]) != 1_700_000_000 {
		t.Errorf("button row = %v", first)
	}
	if second["kind"] != "scheduled" {
		t.Errorf("schedule row kind = %v", second["kind"])
	}
	if _, ok := second["last_run_status"]; ok {
		t.Error("no run yet: no key")
	}
}

// Board #399, D6: every record names the Mac's default agent.
func TestWorkbenchDefaultAgentFollowsTheSetting(t *testing.T) {
	d := db.OpenTestDB(t)
	insertWorkbench(t, d, "Acme", home+"/Projects/acme")
	if got := only(t, payloads(t, workbenchSrc(d, nil)))["default_agent"]; got != "claude_code" {
		t.Errorf("default_agent = %v", got)
	}
	codex := Workbench(d, WorkbenchOptions{Home: home, DefaultAgent: func() agentkind.Kind { return agentkind.Codex }})
	if got := only(t, payloads(t, codex))["default_agent"]; got != "codex_cli" {
		t.Errorf("default_agent = %v", got)
	}
}

func TestHiddenColumnsAreNeverPublished(t *testing.T) {
	d := db.OpenTestDB(t)
	folder := home + "/Projects/acme"
	id := insertWorkbench(t, d, "acme", folder)
	target := insertTarget(t, d, id, targetSeed{})
	insertComment(t, d, id, commentSeed{target: &target})
	session := insertSession(t, d, id, sessionSeed{target: &target, folder: folder})
	linkSession(t, d, session, target)

	sessions := TerminalSessions(d, TerminalSessionOptions{})
	scanned := 0
	for _, src := range []hubslices.Source{workbenchSrc(d, nil), WorkbenchTargets(d, nil), WorkbenchComments(d, nil), sessions} {
		items, err := src.Items(context.Background())
		if err != nil || len(items) == 0 {
			t.Fatalf("%s published nothing to scan (%v)", src.Kind(), err)
		}
		for _, it := range items {
			scanned++
			keys := allKeys(decode(t, it.Payload))
			for _, k := range neverPublishedKeys {
				if keys[k] {
					t.Errorf("%s-%s carries %s", src.Kind(), it.ID, k)
				}
			}
			if strings.Contains(string(it.Payload), folder) || strings.Contains(string(it.Payload), strings.ReplaceAll(folder, "/", `\/`)) {
				t.Errorf("%s-%s carries the raw folder path", src.Kind(), it.ID)
			}
		}
	}
	if scanned != 4 {
		t.Errorf("scanned %d records", scanned)
	}
}

func TestFolderUnderHomeIsShownWithATilde(t *testing.T) {
	cases := []struct{ path, home, want string }{
		{home + "/Projects/acme", home, "~/Projects/acme"},
		{home, home, "~"},
		{home + "/", home + "/", "~/"},
		{"/Users/acme2/Projects/acme", home, "/Users/acme2/Projects/acme"}, // a sibling sharing the prefix
	}
	for _, c := range cases {
		if got := displayPath(c.path, c.home); got != c.want {
			t.Errorf("displayPath(%q, %q) = %q, want %q", c.path, c.home, got, c.want)
		}
	}
}

func TestFolderOutsideHomeIsShownAsIsAndClippedAt300(t *testing.T) {
	d := db.OpenTestDB(t)
	long := "/Volumes/acme/" + strings.Repeat("x", 400)
	insertWorkbench(t, d, "a", "/Volumes/acme/Projects/acme")
	insertWorkbench(t, d, "b", long)
	byName := map[string]map[string]any{}
	for _, p := range payloads(t, workbenchSrc(d, nil)) {
		byName[p["name"].(string)] = p
	}
	if byName["a"]["folder_display"] != "/Volumes/acme/Projects/acme" || byName["a"]["folder_display_clipped"] != nil {
		t.Errorf("a = %v", byName["a"])
	}
	clipped, _ := byName["b"]["folder_display"].(string)
	if runes(clipped) != 300 || !strings.HasPrefix(clipped, "/Volumes/acme/") || !strings.HasSuffix(clipped, "…") ||
		byName["b"]["folder_display_clipped"] != true {
		t.Errorf("b = %q (%d runes) clipped %v", clipped, runes(clipped), byName["b"]["folder_display_clipped"])
	}
}

func rowIDs(t *testing.T, d *db.DB) (full, light []int64, names, lightNames []string) {
	t.Helper()
	err := readTx(context.Background(), d, func(tx *sql.Tx) error {
		rows, err := workbenchRows(context.Background(), tx)
		if err != nil {
			return err
		}
		for _, r := range rows {
			full, names = append(full, r.id), append(names, r.name)
		}
		refs, err := publishedRefs(context.Background(), tx)
		for _, r := range refs {
			light, lightNames = append(light, r.id), append(lightNames, r.name)
		}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return full, light, names, lightNames
}

func TestWorkbenchesOrderByParsedSessionActivity(t *testing.T) {
	d := db.OpenTestDB(t)
	whole := dbStamp(time.Now())
	// The same second with a fraction is later, though it sorts lower as text.
	fractional := strings.TrimSuffix(whole, "Z") + ".900Z"
	earlier := insertWorkbench(t, d, "a", "/tmp/a")
	later := insertWorkbench(t, d, "b", "/tmp/b")
	none := insertWorkbench(t, d, "c", "/tmp/c")
	insertSession(t, d, earlier, sessionSeed{})
	insertSession(t, d, later, sessionSeed{})
	exec(t, d, `UPDATE terminal_sessions SET last_active_at = ? WHERE project_id = ?`, whole, earlier)
	exec(t, d, `UPDATE terminal_sessions SET last_active_at = ? WHERE project_id = ?`, fractional, later)
	full, _, _, _ := rowIDs(t, d)
	if fmt.Sprint(full) != fmt.Sprint([]int64{later, earlier, none}) {
		t.Errorf("order = %v, want newest activity first, no session last", full)
	}
}

// Board #724: the light listing publishes the same workbenches in the same
// order as the full one: parsed activity, no session last, ties in name
// order (case-insensitive, then id), and the 100 cap.
func TestTheLightListingMatchesThePublishedWorkbenches(t *testing.T) {
	d := db.OpenTestDB(t)
	now := time.Now()
	for i := range 104 {
		name := fmt.Sprintf("%s %d", []string{"acme", "Beta", "beta", "Acme"}[i%4], i/4)
		id := insertWorkbench(t, d, name, fmt.Sprintf("/tmp/light-%d", i))
		switch i % 3 {
		case 0:
		case 1:
			insertSession(t, d, id, sessionSeed{lastActive: now.Add(-time.Duration(i) * time.Second)})
		default:
			insertSession(t, d, id, sessionSeed{lastActive: now.Add(-time.Hour)})
		}
	}
	exec(t, d, `UPDATE terminal_sessions SET last_active_at = 'not a date' WHERE id = 1`)
	full, light, names, lightNames := rowIDs(t, d)
	if len(light) != 100 || fmt.Sprint(light) != fmt.Sprint(full) || fmt.Sprint(lightNames) != fmt.Sprint(names) {
		t.Errorf("light %d %v\nfull %v", len(light), light, full)
	}
}

func TestAnUnparsableRequiredDateIsLoggedAndPublishedAs1970(t *testing.T) {
	record := fmt.Sprintf("workbench_target-%d", time.Now().UnixNano())
	if got := requiredDate("not a date", "created_at", record); !got.Equal(time.Unix(0, 0)) {
		t.Errorf("required = %v", got)
	}
	if !dateWarned("created_at", record) || dateWarned("updated_at", record) {
		t.Error("logged once for the record and field")
	}
	if got := requiredDate(dbStamp(time.Unix(1_700_000_000, 0)), "x", record); !got.Equal(time.Unix(1_700_000_000, 0)) {
		t.Errorf("required = %v", got)
	}
	if dateWarned("x", record) {
		t.Error("a good date logs nothing")
	}
}

func TestZeroWorkbenchesPublishZeroRecordsAndNoError(t *testing.T) {
	d := db.OpenTestDB(t)
	sessions := TerminalSessions(d, TerminalSessionOptions{})
	for _, src := range []hubslices.Source{workbenchSrc(d, nil), WorkbenchTargets(d, nil), WorkbenchComments(d, nil), sessions} {
		items, err := src.Items(context.Background())
		if err != nil || len(items) != 0 {
			t.Errorf("%s: %d items, %v", src.Kind(), len(items), err)
		}
	}
}

func TestCountsComeFromTheSwitcherAndDoneCountsOnlyTheUnarchived(t *testing.T) {
	d := db.OpenTestDB(t)
	now := time.Now()
	id := insertWorkbench(t, d, "acme", "/tmp/acme")
	insertTarget(t, d, id, targetSeed{status: "todo"})
	insertTarget(t, d, id, targetSeed{status: "in_progress"})
	insertTarget(t, d, id, targetSeed{status: "blocked"})
	recent := insertTarget(t, d, id, targetSeed{})
	closeTarget(t, d, recent, now.Add(-24*time.Hour))
	old := insertTarget(t, d, id, targetSeed{})
	closeTarget(t, d, old, now.Add(-30*24*time.Hour))
	insertAsk(t, d, id, askSeed{})
	p := only(t, payloads(t, workbenchSrc(d, nil)))
	want := map[string]int64{"open_targets": 3, "in_progress_targets": 1, "blocked_targets": 1, "open_asks": 1,
		"done_targets": 1, "archive_after_days": 14}
	for k, v := range want {
		if num(p[k]) != v {
			t.Errorf("%s = %v, want %d", k, p[k], v)
		}
	}
}

// The spec review author loop's hidden asks are not the owner's to count.
func TestAHiddenSpecLoopAskIsNotCounted(t *testing.T) {
	d := db.OpenTestDB(t)
	id := insertWorkbench(t, d, "acme", "/tmp/acme")
	ask := insertAsk(t, d, id, askSeed{kind: "review"})
	exec(t, d, `INSERT INTO spec_reviews (ask_id, status, queued_at, loop) VALUES (?, 'running', '2026-10-01T00:00:00Z', 'author')`, ask)
	if got := num(only(t, payloads(t, workbenchSrc(d, nil)))["open_asks"]); got != 0 {
		t.Errorf("open_asks = %d", got)
	}
}

func TestAnEmptyBoardIsZeroOfZero(t *testing.T) {
	d := db.OpenTestDB(t)
	insertWorkbench(t, d, "acme", "/tmp/acme")
	p := only(t, payloads(t, workbenchSrc(d, nil)))
	if num(p["open_targets"]) != 0 || num(p["done_targets"]) != 0 {
		t.Errorf("counts = %v", p)
	}
	if _, ok := p["last_session_activity"]; ok {
		t.Error("no session, no activity key")
	}
	if p["branch"] != "" || p["detached"] != false {
		t.Errorf("no git status read yet: %v %v", p["branch"], p["detached"])
	}
}

func TestAtMostAHundredWorkbenchesByLatestSessionActivity(t *testing.T) {
	d := db.OpenTestDB(t)
	now := time.Now()
	for i := range 101 {
		id := insertWorkbench(t, d, fmt.Sprintf("acme %d", i), fmt.Sprintf("/tmp/acme-%d", i))
		// Workbench 0 is the stalest; every other one is newer.
		insertSession(t, d, id, sessionSeed{lastActive: now.Add(time.Duration(i-200) * time.Second)})
	}
	names := map[string]bool{}
	for _, p := range payloads(t, workbenchSrc(d, nil)) {
		names[p["name"].(string)] = true
	}
	if len(names) != 100 || names["acme 0"] {
		t.Errorf("%d names, acme 0 kept: %v", len(names), names["acme 0"])
	}
}

// Review focus 1: a workbench deleted on the Mac leaves the zone with its
// targets and comments, through the publisher.
func TestADeletedWorkbenchLeavesTheZoneWithItsTargetsAndComments(t *testing.T) {
	d := db.OpenTestDB(t)
	kept := insertWorkbench(t, d, "kept", "/tmp/kept")
	insertTarget(t, d, kept, targetSeed{})
	gone := insertWorkbench(t, d, "gone", "/tmp/gone")
	target := insertTarget(t, d, gone, targetSeed{})
	root := insertComment(t, d, gone, commentSeed{target: &target})
	insertComment(t, d, gone, commentSeed{target: &target, parent: &root})

	st, err := state.Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	var (
		mu  sync.Mutex
		now = time.Unix(1_800_000_000, 0).UTC()
	)
	clock := func() time.Time {
		mu.Lock()
		defer mu.Unlock()
		return now
	}
	id, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	kr, err := identity.NewKeyring(id, st, clock)
	if err != nil {
		t.Fatal(err)
	}
	pub := hubslices.NewPublisher(hubslices.Config{
		Store: st, Transport: memfake.New(transport.KindRelay, clock), Sealer: secure.NewSealer(kr),
		DataZone: "data/hubtest-acme", Clock: clock,
		Sources: []hubslices.Source{workbenchSrc(d, nil), WorkbenchTargets(d, nil), WorkbenchComments(d, nil)},
	})
	first, err := pub.Cycle(context.Background(), nil)
	if err != nil || first.Saved != 6 {
		t.Fatalf("first cycle saved %d (%v), want 6", first.Saved, err)
	}
	exec(t, d, `DELETE FROM projects WHERE id = ?`, gone)
	mu.Lock()
	now = now.Add(time.Minute)
	mu.Unlock()
	second, err := pub.Cycle(context.Background(), nil)
	if err != nil || second.Deleted != 4 || second.Saved != 0 {
		t.Fatalf("second cycle deleted %d saved %d (%v), want 4 and 0", second.Deleted, second.Saved, err)
	}
	hashes, err := st.SliceHashes("workbench")
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := hashes[fmt.Sprintf("workbench-%d", kept)]; !ok || len(hashes) != 1 {
		t.Errorf("workbench hashes = %v", hashes)
	}
	if comments, _ := st.SliceHashes("workbench_comment"); len(comments) != 0 {
		t.Errorf("comment hashes = %v", comments)
	}
}
