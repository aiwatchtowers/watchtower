package sources

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
)

// Go twins of WorkbenchTargetSliceTests: board targets only (PROJ-01), the
// archive window (PROJ-15, read-only), the per-workbench caps and the
// comment window.

const day = 24 * time.Hour

func targetPayloads(t *testing.T, d *db.DB) map[int64]map[string]any {
	t.Helper()
	return payloads(t, WorkbenchTargets(d, nil))
}

func commentIDs(t *testing.T, d *db.DB) map[int64]bool {
	t.Helper()
	out := map[int64]bool{}
	for id := range payloads(t, WorkbenchComments(d, nil)) {
		out[id] = true
	}
	return out
}

func ids(v any) []int64 {
	list, _ := v.([]any)
	out := make([]int64, 0, len(list))
	for _, e := range list {
		out = append(out, num(e))
	}
	return out
}

// Board #267: a leaf carries its column title only when the workbench
// defines columns; a parent never.
func TestColumnOnlyWithDefinition(t *testing.T) {
	d := db.OpenTestDB(t)
	project := insertWorkbench(t, d, "acme", "/tmp/acme")
	plain := insertTarget(t, d, project, targetSeed{text: "Plain", status: "in_progress"})
	group := insertTarget(t, d, project, targetSeed{text: "Group", status: "in_progress"})
	leaf := insertTarget(t, d, project, targetSeed{text: "Leaf", status: "in_progress", parent: &group})
	stored := insertTarget(t, d, project, targetSeed{text: "Stored", status: "in_progress"})
	all := targetPayloads(t, d)
	for _, id := range []int64{plain, group, leaf, stored} {
		if _, ok := all[id]["column"]; ok {
			t.Errorf("target %d: no definition, no column key", id)
		}
	}
	for pos, title := range []string{"Coding", "Testing"} {
		exec(t, d, `INSERT INTO workbench_board_columns (project_id, status, title, position, created_at)
VALUES (?, 'in_progress', ?, ?, '2026-10-16T00:00:00Z')`, project, title, pos)
	}
	exec(t, d, `UPDATE targets SET board_column_id = (SELECT id FROM workbench_board_columns WHERE title = 'Testing') WHERE id = ?`, stored)
	all = targetPayloads(t, d)
	if all[plain]["column"] != "Coding" || all[stored]["column"] != "Testing" || all[leaf]["column"] != "Coding" {
		t.Errorf("columns plain %v stored %v leaf %v", all[plain]["column"], all[stored]["column"], all[leaf]["column"])
	}
	if _, ok := all[group]["column"]; ok {
		t.Error("a parent is no card")
	}
	// A hidden status shows no defined column.
	exec(t, d, `INSERT INTO workbench_board_columns (project_id, status, title, position, created_at)
VALUES (?, 'blocked', 'Waiting', 0, '2026-10-16T00:00:00Z')`, project)
	exec(t, d, `UPDATE targets SET status = 'blocked', board_column_id = NULL WHERE id = ?`, plain)
	if got := targetPayloads(t, d)[plain]["column"]; got != "Waiting" {
		t.Errorf("blocked column = %v", got)
	}
	exec(t, d, `UPDATE projects SET board_hidden_statuses = '["blocked"]' WHERE id = ?`, project)
	if _, ok := targetPayloads(t, d)[plain]["column"]; ok {
		t.Error("a hidden status has no column key")
	}
}

func TestWorkbenchTargetMatchesKitFixtureKeys(t *testing.T) {
	d := db.OpenTestDB(t)
	project := insertWorkbench(t, d, "acme", "/tmp/acme")
	parent := insertTarget(t, d, project, targetSeed{text: "Group"})
	child := insertTarget(t, d, project, targetSeed{text: "Archive Closed Targets Now", status: "in_progress", parent: &parent, priority: "high"})
	exec(t, d, `UPDATE targets SET intent = 'Archive on demand.', branch = 'feature/acme', pr = '175', progress = 0.5 WHERE id = ?`, child)
	insertComment(t, d, project, commentSeed{author: "owner", target: &child})
	insertComment(t, d, project, commentSeed{author: "agent", target: &child})
	insertAsk(t, d, project, askSeed{target: &child})
	insertAsk(t, d, project, askSeed{target: &child, status: "answered", answer: "{}"})
	direct := insertSession(t, d, project, sessionSeed{target: &child})
	linked := insertSession(t, d, project, sessionSeed{lastActive: time.Now().Add(-time.Minute)})
	linkSession(t, d, linked, child)
	linkSession(t, d, direct, child)
	insertSession(t, d, project, sessionSeed{kind: "shell", target: &child})

	all := targetPayloads(t, d)
	p := all[child]
	assertWireShape(t, p, kitFixture(t, "workbench/workbench_target.json"),
		"parent_id", "text_clipped", "intent_clipped", "branch_clipped", "pr_clipped",
		"session_ids_more", "last_status_at", "last_status_actor", "work_on_prompt_clipped", "column")
	checks := map[string]bool{
		"parent_id":        num(p["parent_id"]) == parent,
		"status":           p["status"] == "in_progress",
		"priority":         p["priority"] == "high",
		"progress":         float(p["progress"]) == 0.5,
		"branch":           p["branch"] == "feature/acme",
		"pr":               p["pr"] == "175",
		"archived":         p["archived"] == false,
		"open_comments":    num(p["open_comments"]) == 1, // the open owner root
		"unread_for_owner": num(p["unread_for_owner"]) == 1,
		"open_asks":        num(p["open_asks"]) == 1, // only the open ask
		"session_ids":      len(ids(p["session_ids"])) == 2,
		"last_status":      p["last_status_actor"] == "owner",
		"work_on_prompt":   p["work_on_prompt"] == fmt.Sprintf("Work on target #%d using the watchtower-workbench skill.", child),
	}
	for k, ok := range checks {
		if !ok {
			t.Errorf("%s: %v", k, p)
		}
	}
	if g := all[parent]; num(g["children_count"]) != 1 || g["parent_id"] != nil {
		t.Errorf("group = %v", g)
	}
}

func TestWorkbenchCommentMatchesKitFixtureKeys(t *testing.T) {
	d := db.OpenTestDB(t)
	project := insertWorkbench(t, d, "acme", "/tmp/acme")
	target := insertTarget(t, d, project, targetSeed{})
	root := insertComment(t, d, project, commentSeed{author: "owner", target: &target})
	reply := insertComment(t, d, project, commentSeed{target: &target, parent: &root})
	exec(t, d, `UPDATE project_comments SET agent_label = 'claude' WHERE id = ?`, reply)
	all := payloads(t, WorkbenchComments(d, nil))
	p := all[reply]
	assertWireShape(t, p, kitFixture(t, "workbench/workbench_comment.json"),
		"target_id", "parent_id", "agent_label_clipped", "body_clipped")
	if p["agent_label"] != "claude" || p["read"] != false {
		t.Errorf("reply = %v", p)
	}
	if r := all[root]; r["parent_id"] != nil || r["author"] != "owner" {
		t.Errorf("root = %v", r)
	}
}

func TestAPersonalTargetIsNeverPublished(t *testing.T) {
	d := db.OpenTestDB(t)
	project := insertWorkbench(t, d, "acme", "/tmp/acme")
	board := insertTarget(t, d, project, targetSeed{})
	exec(t, d, `INSERT INTO targets (text, level, period_start, period_end) VALUES ('Personal', 'week', '2026-04-20', '2026-04-26')`)
	all := targetPayloads(t, d)
	if _, ok := all[board]; !ok || len(all) != 1 {
		t.Errorf("published %v", all)
	}
}

func TestAnArchivedTargetClosedWithin90DaysIsPublishedAndAnOlderOneIsNot(t *testing.T) {
	d := db.OpenTestDB(t)
	now := time.Now()
	project := insertWorkbench(t, d, "acme", "/tmp/acme")
	recent := insertTarget(t, d, project, targetSeed{text: "89 days"})
	closeTarget(t, d, recent, now.Add(-89*day))
	old := insertTarget(t, d, project, targetSeed{text: "91 days"})
	closeTarget(t, d, old, now.Add(-91*day))
	open := insertTarget(t, d, project, targetSeed{text: "open"})
	insertComment(t, d, project, commentSeed{target: &old})
	all := targetPayloads(t, d)
	if all[recent]["archived"] != true || all[open]["archived"] != false {
		t.Errorf("recent %v open %v", all[recent]["archived"], all[open]["archived"])
	}
	if _, ok := all[old]; ok {
		t.Error("an archived target closed 91 days ago leaves the window")
	}
	if len(commentIDs(t, d)) != 0 {
		t.Error("a comment on an unpublished target is not published")
	}
}

// Review M2: an archived group's window follows its subtree's newest close.
func TestAnArchivedGroupIsPublishedWhileItsChildIs(t *testing.T) {
	d := db.OpenTestDB(t)
	now := time.Now()
	project := insertWorkbench(t, d, "acme", "/tmp/acme")
	group := insertTarget(t, d, project, targetSeed{text: "Group"})
	child := insertTarget(t, d, project, targetSeed{text: "Child", parent: &group})
	closeTarget(t, d, child, now.Add(-80*day))
	closeTarget(t, d, group, now.Add(-100*day))
	all := targetPayloads(t, d)
	if all[child]["archived"] != true || all[group]["archived"] != true || num(all[child]["parent_id"]) != group {
		t.Errorf("child %v group %v", all[child], all[group])
	}
}

func TestOnEqualCloseTimesAnArchivedGroupRanksBeforeItsChildren(t *testing.T) {
	d := db.OpenTestDB(t)
	now := time.Now()
	project := insertWorkbench(t, d, "acme", "/tmp/acme")
	group := insertTarget(t, d, project, targetSeed{text: "Group"})
	var children []int64
	for i := range 500 {
		children = append(children, insertTarget(t, d, project, targetSeed{text: fmt.Sprintf("c%d", i), parent: &group}))
	}
	for _, c := range children {
		closeTarget(t, d, c, now.Add(-30*day))
	}
	closeTarget(t, d, group, now.Add(-30*day))
	all := targetPayloads(t, d)
	missing := 0
	for _, c := range children {
		if _, ok := all[c]; !ok {
			missing++
		}
	}
	if _, ok := all[group]; len(all) != 500 || !ok || missing != 1 {
		t.Errorf("%d published, group kept %v, %d children left", len(all), ok, missing)
	}
}

func TestADoneTargetNotYetArchivedIsPublishedAsNotArchived(t *testing.T) {
	d := db.OpenTestDB(t)
	project := insertWorkbench(t, d, "acme", "/tmp/acme")
	target := insertTarget(t, d, project, targetSeed{})
	closeTarget(t, d, target, time.Now().Add(-2*day))
	if got := targetPayloads(t, d)[target]["archived"]; got != false {
		t.Errorf("archived = %v: closed 2 days ago, archive after 14", got)
	}
}

func TestWorkbenchCapsKeepThe2000NewestNonArchivedTargets(t *testing.T) {
	d := db.OpenTestDB(t)
	project := insertWorkbench(t, d, "acme", "/tmp/acme")
	for i := range 2001 {
		insertTarget(t, d, project, targetSeed{text: fmt.Sprintf("t%d", i)})
	}
	// The lowest id is the stalest, every later one a second newer.
	exec(t, d, `UPDATE targets SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-' || (5000 - id) || ' seconds')`)
	var oldest int64
	if err := d.QueryRow(`SELECT MIN(id) FROM targets`).Scan(&oldest); err != nil {
		t.Fatal(err)
	}
	all := targetPayloads(t, d)
	if _, ok := all[oldest]; len(all) != 2000 || ok {
		t.Errorf("%d published, oldest kept %v", len(all), ok)
	}
	if got := num(only(t, payloads(t, workbenchSrc(d, nil)))["targets_more"]); got != 1 {
		t.Errorf("targets_more = %d", got)
	}
}

func TestArchivedTargetsAreCappedAt500NewestClosed(t *testing.T) {
	d := db.OpenTestDB(t)
	now := time.Now()
	project := insertWorkbench(t, d, "acme", "/tmp/acme")
	var first int64
	for i := range 501 {
		id := insertTarget(t, d, project, targetSeed{text: fmt.Sprintf("a%d", i)})
		closeTarget(t, d, id, now.Add(-30*day+time.Duration(i)*time.Minute))
		if i == 0 {
			first = id
		}
	}
	all := targetPayloads(t, d)
	if _, ok := all[first]; len(all) != 500 || ok {
		t.Errorf("%d published, earliest close kept %v", len(all), ok)
	}
	for id, p := range all {
		if p["archived"] != true {
			t.Errorf("target %d not archived", id)
		}
	}
	if got := num(only(t, payloads(t, workbenchSrc(d, nil)))["targets_more"]); got != 1 {
		t.Errorf("targets_more = %d", got)
	}
}

func TestTextFieldsAndSessionIDsAreCapped(t *testing.T) {
	d := db.OpenTestDB(t)
	project := insertWorkbench(t, d, "acme", "/tmp/acme")
	target := insertTarget(t, d, project, targetSeed{text: strings.Repeat("t", 301)})
	exec(t, d, `UPDATE targets SET intent = ?, branch = ?, pr = ? WHERE id = ?`,
		strings.Repeat("i", 4001), strings.Repeat("b", 121), strings.Repeat("p", 121), target)
	for i := range 21 {
		insertSession(t, d, project, sessionSeed{target: &target, lastActive: time.Now().Add(-time.Duration(i) * time.Second)})
	}
	p := targetPayloads(t, d)[target]
	for field, limit := range map[string]int{"text": 300, "intent": 4000, "branch": 120, "pr": 120} {
		if runes(p[field]) != limit || p[field+"_clipped"] != true {
			t.Errorf("%s: %d runes, clipped %v", field, runes(p[field]), p[field+"_clipped"])
		}
	}
	if len(ids(p["session_ids"])) != 20 || num(p["session_ids_more"]) != 1 {
		t.Errorf("session_ids %d more %v", len(ids(p["session_ids"])), p["session_ids_more"])
	}
	if _, ok := p["work_on_prompt_clipped"]; ok {
		t.Error("the prompt fits")
	}
}

// A target's session_ids name its codex sessions too (board #399); a shell
// never.
func TestCodexSessionsAreListedOnTheirTarget(t *testing.T) {
	d := db.OpenTestDB(t)
	now := time.Now()
	project := insertWorkbench(t, d, "acme", "/tmp/acme")
	target := insertTarget(t, d, project, targetSeed{})
	claude := insertSession(t, d, project, sessionSeed{target: &target, lastActive: now.Add(-time.Minute)})
	codex := insertSession(t, d, project, sessionSeed{kind: "codex", target: &target, lastActive: now})
	linked := insertSession(t, d, project, sessionSeed{kind: "codex", lastActive: now.Add(-2 * time.Minute)})
	linkSession(t, d, linked, target)
	insertSession(t, d, project, sessionSeed{kind: "shell", target: &target})
	if got := ids(targetPayloads(t, d)[target]["session_ids"]); fmt.Sprint(got) != fmt.Sprint([]int64{codex, claude, linked}) {
		t.Errorf("session_ids = %v", got)
	}
}

func TestTheNewest200CommentsPerTargetArePublished(t *testing.T) {
	d := db.OpenTestDB(t)
	project := insertWorkbench(t, d, "acme", "/tmp/acme")
	target := insertTarget(t, d, project, targetSeed{})
	for i := range 201 {
		insertComment(t, d, project, commentSeed{body: fmt.Sprintf("c%d", i), target: &target})
	}
	exec(t, d, `UPDATE project_comments SET created_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-' || (5000 - id) || ' seconds')`)
	var oldest int64
	if err := d.QueryRow(`SELECT MIN(id) FROM project_comments`).Scan(&oldest); err != nil {
		t.Fatal(err)
	}
	got := commentIDs(t, d)
	if len(got) != 200 || got[oldest] {
		t.Errorf("%d comments, oldest kept %v", len(got), got[oldest])
	}
}

func TestAReplyNamingOnlyItsParentCountsTowardItsRootsTarget(t *testing.T) {
	d := db.OpenTestDB(t)
	project := insertWorkbench(t, d, "acme", "/tmp/acme")
	target := insertTarget(t, d, project, targetSeed{})
	root := insertComment(t, d, project, commentSeed{author: "owner", target: &target})
	reply := insertComment(t, d, project, commentSeed{parent: &root})
	all := payloads(t, WorkbenchComments(d, nil))
	if len(all) != 2 || all[root] == nil || all[reply] == nil {
		t.Fatalf("published %v", all)
	}
	if p := all[reply]; p["target_id"] != nil || num(p["parent_id"]) != root {
		t.Errorf("reply = %v", p)
	}
}

func TestCommentTextIsCappedAndReadFollowsReadAt(t *testing.T) {
	d := db.OpenTestDB(t)
	project := insertWorkbench(t, d, "acme", "/tmp/acme")
	target := insertTarget(t, d, project, targetSeed{})
	id := insertComment(t, d, project, commentSeed{body: strings.Repeat("b", 4001), target: &target, readAt: dbStamp(time.Now())})
	exec(t, d, `UPDATE project_comments SET agent_label = ? WHERE id = ?`, strings.Repeat("l", 61), id)
	p := only(t, payloads(t, WorkbenchComments(d, nil)))
	if runes(p["body"]) != 4000 || p["body_clipped"] != true || runes(p["agent_label"]) != 60 ||
		p["agent_label_clipped"] != true || p["read"] != true {
		t.Errorf("comment = body %d %v label %d %v read %v", runes(p["body"]), p["body_clipped"],
			runes(p["agent_label"]), p["agent_label_clipped"], p["read"])
	}
}

// clipText cuts at a grapheme boundary: a ZWJ family emoji is kept or
// dropped whole.
func TestClipTextCountsGraphemes(t *testing.T) {
	family := "👩‍👩‍👧"
	text, clipped := clipText(strings.Repeat(family, 3), 3)
	if text != strings.Repeat(family, 3) || clipped != nil {
		t.Errorf("3 graphemes fit 3: %q %v", text, clipped)
	}
	text, clipped = clipText(strings.Repeat(family, 4), 3)
	if text != family+family+"…" || clipped == nil || !*clipped {
		t.Errorf("clipped = %q %v", text, clipped)
	}
	if text, clipped := clipText("abc", 0); text != "" || clipped == nil {
		t.Errorf("limit 0 = %q %v", text, clipped)
	}
}
