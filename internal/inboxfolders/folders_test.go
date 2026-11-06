package inboxfolders

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// fixture is a Store over a fresh in-memory database with the migration's
// seeds: the root, Needs approval, revision 1.
type fixture struct {
	t         *testing.T
	ctx       context.Context
	d         *db.DB
	s         *Store
	root      int64
	approvals int64
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	d := db.OpenTestDB(t)
	f := &fixture{t: t, ctx: context.Background(), d: d, s: NewStore(d)}
	tree, err := f.s.List(f.ctx)
	require.NoError(t, err)
	f.root, f.approvals = tree.Folders[0].ID, tree.Folders[1].ID
	return f
}

func ptr[T any](v T) *T { return &v }

func (f *fixture) rev() int64 {
	f.t.Helper()
	tree, err := f.s.List(f.ctx)
	require.NoError(f.t, err)
	return tree.Revision
}

func (f *fixture) tree() Tree {
	f.t.Helper()
	tree, err := f.s.List(f.ctx)
	require.NoError(f.t, err)
	return tree
}

// create adds a folder under parent (0 = root) at the current revision.
func (f *fixture) create(title string, parent int64) Folder {
	f.t.Helper()
	req := CreateRequest{Title: title, ExpectRevision: f.rev()}
	if parent != 0 {
		req.ParentID = &parent
	}
	_, folder, err := f.s.Create(f.ctx, req)
	require.NoError(f.t, err, "create %q", title)
	return folder
}

// childTitles lists parent's children titles in position order, with their
// positions checked dense.
func (f *fixture) childTitles(parent int64) []string {
	f.t.Helper()
	titles := []string{}
	for _, folder := range f.tree().Folders {
		if folder.ParentID != nil && *folder.ParentID == parent {
			require.Equal(f.t, len(titles), folder.Position, "positions of %q's children are dense", parent)
			titles = append(titles, folder.Title)
		}
	}
	return titles
}

func (f *fixture) count(query string, args ...any) int {
	f.t.Helper()
	var n int
	require.NoError(f.t, f.d.QueryRow(query, args...).Scan(&n))
	return n
}

// automation inserts an owner automation (or the built-in builtinID) and
// returns its id.
func (f *fixture) automation(slug, builtinID string) int64 {
	f.t.Helper()
	var id int64
	var err error
	if builtinID == "" {
		err = f.d.QueryRow(`INSERT INTO automations (slug, scope, path, approval_hash) VALUES (?, 'personal', ?, 'h-1')
			RETURNING id`, slug, "/acme/automations/"+slug+".md").Scan(&id)
	} else {
		err = f.d.QueryRow(`INSERT INTO automations (slug, scope, path, origin, builtin_id) VALUES (?, 'personal', ?, 'builtin', ?)
			RETURNING id`, slug, "builtin:"+builtinID, builtinID).Scan(&id)
	}
	require.NoError(f.t, err)
	return id
}

// output stores an inbox artifact of automation a, in folder (nil = follows
// the route), and returns its id.
func (f *fixture) output(a int64, folder *int64) int64 {
	f.t.Helper()
	var run, id int64
	require.NoError(f.t, f.d.QueryRow(`INSERT INTO automation_runs (automation_id, trigger, status) VALUES (?, 'manual', 'succeeded')
		RETURNING id`, a).Scan(&run))
	require.NoError(f.t, f.d.QueryRow(`INSERT INTO automation_outputs (automation_id, run_id, kind, title, body, folder_id)
		VALUES (?, ?, 'inbox', 't', 'b', ?) RETURNING id`, a, run, folder).Scan(&id))
	return id
}

func (f *fixture) artifactFolder(output int64) int64 {
	f.t.Helper()
	folder, err := f.d.InboxArtifactFolder(f.ctx, output)
	require.NoError(f.t, err)
	return folder
}

// unchanged asserts a refused write left the tree as before.
func (f *fixture) unchanged(before Tree) {
	f.t.Helper()
	assert.Equal(f.t, before, f.tree(), "a refused write changes nothing")
}

// --- FOLDER-01 -------------------------------------------------------------

// TestFolder01_DeleteMovesContentsUp guards FOLDER-01: deleting a folder
// deletes the folder row only. Its child folders move to its parent
// (appended, order kept), the automations routed to it and the artifacts
// placed in it explicitly move to the parent, and the counts are reported.
func TestFolder01_DeleteMovesContentsUp(t *testing.T) {
	f := newFixture(t)
	other := f.create("Other", 0)
	release := f.create("Release", 0)
	alpha := f.create("Alpha", release.ID)
	beta := f.create("Beta", release.ID)
	f.create("Gamma", alpha.ID) // a grandchild rides along with its parent

	routed := f.automation("acme-digest", "")
	elsewhere := f.automation("acme-weekly", "")
	_, _, _, err := f.s.Route(f.ctx, routed, RouteRequest{FolderID: &release.ID, ExpectRevision: f.rev()})
	require.NoError(t, err)
	_, _, _, err = f.s.Route(f.ctx, elsewhere, RouteRequest{FolderID: &other.ID, ExpectRevision: f.rev()})
	require.NoError(t, err)
	followsRoute := f.output(routed, nil)
	explicit := f.output(elsewhere, &release.ID)
	explicitElsewhere := f.output(routed, &other.ID)

	outputsBefore := f.count(`SELECT COUNT(*) FROM automation_outputs`)
	automationsBefore := f.count(`SELECT COUNT(*) FROM automations`)
	foldersBefore := f.count(`SELECT COUNT(*) FROM inbox_folders`)

	tree, moved, err := f.s.Delete(f.ctx, release.ID, f.rev())
	require.NoError(t, err)
	assert.Equal(t, Moved{Folders: 2, Automations: 1, Artifacts: 1, Renamed: []Renamed{}}, moved)

	assert.Equal(t, []string{"Needs approval", "Other", "Alpha", "Beta"}, f.childTitles(f.root))
	assert.Equal(t, []string{"Gamma"}, f.childTitles(alpha.ID))
	_, ok := tree.find(release.ID)
	assert.False(t, ok)
	_, ok = tree.find(beta.ID)
	assert.True(t, ok)

	rootFolder, _ := tree.find(f.root)
	assert.Equal(t, []int64{routed}, rootFolder.AutomationIDs, "the route moved to the parent")
	assert.Equal(t, f.root, f.artifactFolder(followsRoute))
	assert.Equal(t, f.root, f.artifactFolder(explicit))
	assert.Equal(t, other.ID, f.artifactFolder(explicitElsewhere))

	assert.Equal(t, outputsBefore, f.count(`SELECT COUNT(*) FROM automation_outputs`), "no artifact deleted")
	assert.Equal(t, automationsBefore, f.count(`SELECT COUNT(*) FROM automations`), "no automation deleted")
	assert.Equal(t, foldersBefore-1, f.count(`SELECT COUNT(*) FROM inbox_folders`), "only the folder row went")
	assert.Equal(t, 2, f.count(`SELECT COUNT(*) FROM inbox_folder_routes`), "no route deleted")
}

func TestDelete_EmptyFolderMovesNothing(t *testing.T) {
	f := newFixture(t)
	empty := f.create("Empty", 0)
	_, moved, err := f.s.Delete(f.ctx, empty.ID, f.rev())
	require.NoError(t, err)
	assert.Equal(t, Moved{Renamed: []Renamed{}}, moved)
	assert.Equal(t, []string{"Needs approval"}, f.childTitles(f.root))
}

func TestDelete_TitleClashIgnoringCaseRenamesMovedChild(t *testing.T) {
	f := newFixture(t)
	f.create("Notes", 0)
	release := f.create("Release", 0)
	notes := f.create("notes", release.ID)
	approvalsLike := f.create("Needs Approval", release.ID)
	f.create("Other", release.ID)

	tree, moved, err := f.s.Delete(f.ctx, release.ID, f.rev())
	require.NoError(t, err)
	assert.Equal(t, []Renamed{
		{ID: notes.ID, From: "notes", To: "notes (2)"},
		{ID: approvalsLike.ID, From: "Needs Approval", To: "Needs Approval (2)"},
	}, moved.Renamed)
	assert.Equal(t, []string{"Needs approval", "Notes", "notes (2)", "Needs Approval (2)", "Other"}, f.childTitles(f.root))
	got, _ := tree.find(notes.ID)
	assert.Equal(t, notes.Slug, got.Slug, "a rename never changes the slug")

	// Sibling titles stay unique, so the usual writes keep working.
	_, _, err = f.s.Update(f.ctx, notes.ID, UpdateRequest{Title: ptr("notes (2)"), Icon: ptr("bell"), ExpectRevision: f.rev()})
	require.NoError(t, err)
	parked := f.create("Parked", 0)
	_, _, err = f.s.Move(f.ctx, notes.ID, parked.ID, 0, f.rev())
	require.NoError(t, err)
	_, _, err = f.s.Move(f.ctx, notes.ID, f.root, 9, f.rev())
	require.NoError(t, err)
}

func TestDelete_TitleClashChainsNumbers(t *testing.T) {
	f := newFixture(t)
	f.create("Notes", 0)
	f.create("Notes (2)", 0)
	release := f.create("Release", 0)
	notes := f.create("notes", release.ID)
	f.create("NOTES (3)", release.ID) // a moving child's title is taken too

	_, moved, err := f.s.Delete(f.ctx, release.ID, f.rev())
	require.NoError(t, err)
	assert.Equal(t, []Renamed{{ID: notes.ID, From: "notes", To: "notes (4)"}}, moved.Renamed)
	assert.Equal(t, []string{"Needs approval", "Notes", "Notes (2)", "notes (4)", "NOTES (3)"}, f.childTitles(f.root))
}

// The renames use the same case rule as every other write (EqualFold), so
// Σ, σ and ς are one title.
func TestDelete_TitleClashFoldsLikeTheWrites(t *testing.T) {
	f := newFixture(t)
	f.create("Σ", 0)
	f.create("ς (2)", 0)
	release := f.create("Release", 0)
	upper := f.create("Σ", release.ID)
	other := f.create("Other", 0)
	final := f.create("ς", other.ID)

	_, moved, err := f.s.Delete(f.ctx, release.ID, f.rev())
	require.NoError(t, err)
	assert.Equal(t, []Renamed{{ID: upper.ID, From: "Σ", To: "Σ (3)"}}, moved.Renamed,
		"Σ (2) would clash with ς (2)")

	_, moved, err = f.s.Delete(f.ctx, other.ID, f.rev())
	require.NoError(t, err)
	assert.Equal(t, []Renamed{{ID: final.ID, From: "ς", To: "ς (4)"}}, moved.Renamed,
		"ς clashes with the staying Σ")
	assert.Equal(t, []string{"Needs approval", "Σ", "ς (2)", "Σ (3)", "ς (4)"}, f.childTitles(f.root))
}

func TestDelete_TitleClashRenameKeepsTheCap(t *testing.T) {
	f := newFixture(t)
	long := strings.Repeat("a", MaxTitleRunes-1) + "я"
	f.create(long, 0)
	release := f.create("Release", 0)
	kid := f.create(strings.ToUpper(long), release.ID)

	_, moved, err := f.s.Delete(f.ctx, release.ID, f.rev())
	require.NoError(t, err)
	require.Len(t, moved.Renamed, 1)
	want := strings.Repeat("A", MaxTitleRunes-4) + " (2)"
	assert.Equal(t, Renamed{ID: kid.ID, From: strings.ToUpper(long), To: want}, moved.Renamed[0])
	assert.Equal(t, MaxTitleRunes, utf8.RuneCountInString(want))
	_, err = cleanTitle(want)
	assert.NoError(t, err, "the new title passes the title rules")
}

// Deleting a hidden folder brings its visible children back into the menu:
// hidden belongs to the deleted folder, not to what moves up.
func TestDelete_HiddenFolderItsVisibleChildrenComeBack(t *testing.T) {
	f := newFixture(t)
	archive := f.create("Archive", 0)
	kid := f.create("Old", archive.ID)
	hiddenKid := f.create("Older", archive.ID)
	_, _, err := f.s.Update(f.ctx, hiddenKid.ID, UpdateRequest{Hidden: ptr(true), ExpectRevision: f.rev()})
	require.NoError(t, err)
	_, _, err = f.s.Update(f.ctx, archive.ID, UpdateRequest{Hidden: ptr(true), ExpectRevision: f.rev()})
	require.NoError(t, err)

	tree, _, err := f.s.Delete(f.ctx, archive.ID, f.rev())
	require.NoError(t, err)
	got, _ := tree.find(kid.ID)
	require.NotNil(t, got.ParentID)
	assert.Equal(t, f.root, *got.ParentID)
	assert.False(t, got.Hidden, "no hidden ancestor left: shown in the menu and counted in the badge")
	got, _ = tree.find(hiddenKid.ID)
	assert.True(t, got.Hidden, "a child hidden on its own stays hidden")
}

func TestDelete_AtMaxDepthChildrenMoveUpOneLevel(t *testing.T) {
	f := newFixture(t)
	a := f.create("A", 0)
	b := f.create("B", a.ID)
	c := f.create("C", b.ID) // depth 3
	tree, _, err := f.s.Delete(f.ctx, b.ID, f.rev())
	require.NoError(t, err)
	got, _ := tree.find(c.ID)
	require.NotNil(t, got.ParentID)
	assert.Equal(t, a.ID, *got.ParentID)
	// The freed level is usable again: C may take a child.
	f.create("D", c.ID)
}

// --- create ----------------------------------------------------------------

func TestCreate_AppendsWithSlugAndBumpsRevision(t *testing.T) {
	f := newFixture(t)
	tree, folder, err := f.s.Create(f.ctx, CreateRequest{Title: "  Release  ", Icon: "flag", ExpectRevision: 1})
	require.NoError(t, err)
	assert.Equal(t, int64(2), tree.Revision)
	assert.Equal(t, "Release", folder.Title)
	assert.Equal(t, "release", folder.Slug)
	assert.Equal(t, "flag", folder.Icon)
	assert.Equal(t, kindOwner, folder.Kind)
	assert.Equal(t, 1, folder.Position, "after Needs approval")
	assert.Equal(t, []int64{}, folder.AutomationIDs)
	require.NotNil(t, folder.ParentID)
	assert.Equal(t, f.root, *folder.ParentID)
	assert.Equal(t, int64(2), f.rev())
}

func TestCreate_Positions(t *testing.T) {
	f := newFixture(t)
	f.create("A", 0)
	f.create("B", 0)
	_, _, err := f.s.Create(f.ctx, CreateRequest{Title: "First", Position: ptr(0), ExpectRevision: f.rev()})
	require.NoError(t, err)
	_, _, err = f.s.Create(f.ctx, CreateRequest{Title: "Far", Position: ptr(99), ExpectRevision: f.rev()})
	require.NoError(t, err)
	_, _, err = f.s.Create(f.ctx, CreateRequest{Title: "Mid", Position: ptr(2), ExpectRevision: f.rev()})
	require.NoError(t, err)
	assert.Equal(t, []string{"Needs approval", "First", "Mid", "A", "B", "Far"}, f.childTitles(f.root),
		"0 lands after the pinned Needs approval, past the end lands last")

	before := f.tree()
	_, _, err = f.s.Create(f.ctx, CreateRequest{Title: "Neg", Position: ptr(-1), ExpectRevision: before.Revision})
	assert.ErrorIs(t, err, ErrBadPosition)
	f.unchanged(before)
}

func TestCreate_UnderParentAndRefusedParents(t *testing.T) {
	f := newFixture(t)
	release := f.create("Release", 0)
	child := f.create("Notes", release.ID)
	require.NotNil(t, child.ParentID)
	assert.Equal(t, release.ID, *child.ParentID)
	assert.Equal(t, 0, child.Position)

	before := f.tree()
	_, _, err := f.s.Create(f.ctx, CreateRequest{Title: "X", ParentID: &f.approvals, ExpectRevision: before.Revision})
	assert.ErrorIs(t, err, ErrApprovalsHoldsNothingElse)
	_, _, err = f.s.Create(f.ctx, CreateRequest{Title: "X", ParentID: ptr(int64(9999)), ExpectRevision: before.Revision})
	assert.ErrorIs(t, err, ErrNoFolder)
	assert.EqualError(t, err, "no folder 9999")
	f.unchanged(before)
}

func TestCreate_DepthLimit(t *testing.T) {
	f := newFixture(t)
	a := f.create("A", 0)
	b := f.create("B", a.ID)
	c := f.create("C", b.ID) // depth 3: allowed
	assert.Equal(t, 3, MaxDepth)

	before := f.tree()
	_, _, err := f.s.Create(f.ctx, CreateRequest{Title: "D", ParentID: &c.ID, ExpectRevision: before.Revision})
	assert.ErrorIs(t, err, ErrTooDeep)
	assert.EqualError(t, err, "folders nest at most 3 deep")
	f.unchanged(before)
}

func TestCreate_CountLimit(t *testing.T) {
	f := newFixture(t)
	for i := range MaxOwnerFolders {
		f.create(fmt.Sprintf("Folder %d", i), 0)
	}
	before := f.tree()
	assert.Len(t, before.Folders, MaxOwnerFolders+2)
	_, _, err := f.s.Create(f.ctx, CreateRequest{Title: "One more", ExpectRevision: before.Revision})
	assert.ErrorIs(t, err, ErrTooMany)
	f.unchanged(before)
}

func TestCreate_Titles(t *testing.T) {
	f := newFixture(t)
	ok := []string{
		strings.Repeat("a", MaxTitleRunes),
		strings.Repeat("я", MaxTitleRunes),
		strings.Repeat("a", MaxTitleRunes-1) + "🚀",
		"Release\n",              // trimmed
		"Family 👨\u200D👩\u200D👧", // the zero-width joiner is allowed
	}
	for _, title := range ok {
		_, _, err := f.s.Create(f.ctx, CreateRequest{Title: title, ExpectRevision: f.rev()})
		assert.NoError(t, err, "%q", title)
	}
	bad := []string{
		"",
		"   \t ",
		strings.Repeat("a", MaxTitleRunes+1),
		strings.Repeat("a", MaxTitleRunes) + "🚀",
		"Rel\nease",
		"Rel\x00ease",
		"Rel\u0085ease",
		"Rel\u2028ease",
		"Rel\u2029ease",
		"Rel\u202Eease",
		"Rel\u200Bease",
		"Rel\u2060ease", // word joiner: Cf, refused unlike U+200D
		"Rel\uFEFFease",
		"bad\xffutf8",
	}
	before := f.tree()
	for _, title := range bad {
		_, _, err := f.s.Create(f.ctx, CreateRequest{Title: title, ExpectRevision: before.Revision})
		assert.ErrorIs(t, err, ErrBadTitle, "%q", title)
	}
	f.unchanged(before)
}

func TestCreate_DuplicateTitles(t *testing.T) {
	f := newFixture(t)
	release := f.create("Release", 0)
	before := f.tree()
	for _, title := range []string{"release", "RELEASE ", "needs APPROVAL"} {
		_, _, err := f.s.Create(f.ctx, CreateRequest{Title: title, ExpectRevision: before.Revision})
		assert.ErrorIs(t, err, ErrDuplicateTitle, "%q", title)
	}
	_, _, err := f.s.Create(f.ctx, CreateRequest{Title: "release", ExpectRevision: before.Revision})
	assert.EqualError(t, err, `a folder named "release" already exists here`)
	f.unchanged(before)

	// The same title under another parent is a different folder.
	nested := f.create("Release", release.ID)
	assert.Equal(t, "release-2", nested.Slug)
}

func TestCreate_Slugs(t *testing.T) {
	f := newFixture(t)
	a := f.create("Release", 0)
	b := f.create("Release!", a.ID)
	c := f.create("  Q3 — Launch & Plans ", 0)
	d := f.create("Входящие", 0)
	e := f.create("Почта", 0)
	g := f.create("Inbox", a.ID)
	h := f.create("Needs Approval", a.ID)
	assert.Equal(t, "release", a.Slug)
	assert.Equal(t, "release-2", b.Slug)
	assert.Equal(t, "q3-launch-plans", c.Slug)
	assert.Equal(t, "folder", d.Slug)
	assert.Equal(t, "folder-2", e.Slug)
	assert.Equal(t, "inbox-2", g.Slug, "the root's slug is taken")
	assert.Equal(t, "needs-approval-2", h.Slug)
}

func TestCreate_Icons(t *testing.T) {
	f := newFixture(t)
	empty := f.create("Plain", 0)
	assert.Equal(t, "", empty.Icon, "'' is the kind's default")
	before := f.tree()
	_, _, err := f.s.Create(f.ctx, CreateRequest{Title: "X", Icon: "rocket.fake", ExpectRevision: before.Revision})
	assert.ErrorIs(t, err, ErrUnknownIcon)
	assert.EqualError(t, err, `unknown icon "rocket.fake"`)
	f.unchanged(before)
}

func TestIcons_AllowlistShape(t *testing.T) {
	assert.GreaterOrEqual(t, len(allowedIcons), 20)
	for _, name := range []string{"folder", "tray", "flag", "bolt", "person.2", "doc.text", "calendar",
		"shippingbox", "lightbulb", "bell"} {
		assert.True(t, allowedIcons[name], name)
	}
	assert.False(t, allowedIcons[""], "'' is not a name; checkIcon accepts it as the default")
}

// --- update ----------------------------------------------------------------

func TestUpdate_RenameKeepsSlugIconHidden(t *testing.T) {
	f := newFixture(t)
	release := f.create("Release", 0)
	tree, got, err := f.s.Update(f.ctx, release.ID, UpdateRequest{
		Title: ptr("Shipping"), Icon: ptr("shippingbox"), Hidden: ptr(true), ExpectRevision: f.rev(),
	})
	require.NoError(t, err)
	assert.Equal(t, "Shipping", got.Title)
	assert.Equal(t, "release", got.Slug, "a rename never changes the slug")
	assert.Equal(t, "shippingbox", got.Icon)
	assert.True(t, got.Hidden)
	assert.Equal(t, int64(3), tree.Revision)

	_, got, err = f.s.Update(f.ctx, release.ID, UpdateRequest{Hidden: ptr(false), Icon: ptr(""), ExpectRevision: f.rev()})
	require.NoError(t, err)
	assert.False(t, got.Hidden)
	assert.Equal(t, "", got.Icon)
	assert.Equal(t, "Shipping", got.Title, "fields left nil stay")

	// Its own title in another case is not a duplicate.
	_, got, err = f.s.Update(f.ctx, release.ID, UpdateRequest{Title: ptr("SHIPPING"), ExpectRevision: f.rev()})
	require.NoError(t, err)
	assert.Equal(t, "SHIPPING", got.Title)
}

func TestUpdate_Refusals(t *testing.T) {
	f := newFixture(t)
	f.create("Release", 0)
	notes := f.create("Notes", 0)
	before := f.tree()
	rev := before.Revision
	cases := []struct {
		id   int64
		req  UpdateRequest
		want error
	}{
		{notes.ID, UpdateRequest{Title: ptr("release"), ExpectRevision: rev}, ErrDuplicateTitle},
		{notes.ID, UpdateRequest{Title: ptr(" "), ExpectRevision: rev}, ErrBadTitle},
		{notes.ID, UpdateRequest{Icon: ptr("nope"), ExpectRevision: rev}, ErrUnknownIcon},
		{9999, UpdateRequest{Hidden: ptr(true), ExpectRevision: rev}, ErrNoFolder},
		{f.root, UpdateRequest{Title: ptr("Mail"), ExpectRevision: rev}, ErrRootFixed},
		{f.root, UpdateRequest{Hidden: ptr(true), ExpectRevision: rev}, ErrRootFixed},
		{f.approvals, UpdateRequest{Title: ptr("Approvals"), ExpectRevision: rev}, ErrApprovalsFixed},
		{f.approvals, UpdateRequest{Icon: ptr("bell"), ExpectRevision: rev}, ErrApprovalsFixed},
		{f.approvals, UpdateRequest{Hidden: ptr(true), ExpectRevision: rev}, ErrApprovalsFixed},
	}
	for i, c := range cases {
		_, _, err := f.s.Update(f.ctx, c.id, c.req)
		assert.ErrorIs(t, err, c.want, "case %d", i)
	}
	f.unchanged(before)
}

// --- move ------------------------------------------------------------------

func TestMove_ReorderWithinParent(t *testing.T) {
	f := newFixture(t)
	a := f.create("A", 0)
	f.create("B", 0)
	f.create("C", 0)
	_, got, err := f.s.Move(f.ctx, a.ID, f.root, 3, f.rev())
	require.NoError(t, err)
	assert.Equal(t, 3, got.Position)
	assert.Equal(t, []string{"Needs approval", "B", "C", "A"}, f.childTitles(f.root))

	_, _, err = f.s.Move(f.ctx, a.ID, f.root, 0, f.rev())
	require.NoError(t, err)
	assert.Equal(t, []string{"Needs approval", "A", "B", "C"}, f.childTitles(f.root),
		"0 in the root lands after Needs approval")

	_, _, err = f.s.Move(f.ctx, a.ID, f.root, 50, f.rev())
	require.NoError(t, err)
	assert.Equal(t, []string{"Needs approval", "B", "C", "A"}, f.childTitles(f.root), "past the end = last")
}

func TestMove_ReparentRenumbersBothLists(t *testing.T) {
	f := newFixture(t)
	a := f.create("A", 0)
	b := f.create("B", 0)
	f.create("A1", a.ID)
	a2 := f.create("A2", a.ID)
	f.create("A3", a.ID)
	f.create("B1", b.ID)
	f.create("Deep", a2.ID)

	_, got, err := f.s.Move(f.ctx, a2.ID, b.ID, 0, f.rev())
	require.NoError(t, err)
	require.NotNil(t, got.ParentID)
	assert.Equal(t, b.ID, *got.ParentID)
	assert.Equal(t, []string{"A1", "A3"}, f.childTitles(a.ID))
	assert.Equal(t, []string{"A2", "B1"}, f.childTitles(b.ID))
	assert.Equal(t, []string{"Deep"}, f.childTitles(a2.ID), "the subtree moves along")

	tree := f.tree()
	var order []string
	for _, folder := range tree.Folders {
		order = append(order, folder.Title)
	}
	assert.Equal(t, []string{"Inbox", "Needs approval", "A", "A1", "A3", "B", "A2", "Deep", "B1"}, order, "pre-order")
}

func TestMove_Refusals(t *testing.T) {
	f := newFixture(t)
	a := f.create("A", 0)
	b := f.create("B", a.ID)
	c := f.create("C", b.ID)
	x := f.create("X", 0)
	f.create("Y", x.ID)
	dup := f.create("B", 0)
	before := f.tree()
	rev := before.Revision
	cases := []struct {
		name       string
		id, parent int64
		pos        int
		want       error
	}{
		{"under itself", a.ID, a.ID, 0, ErrCycle},
		{"under its descendant", a.ID, c.ID, 0, ErrCycle},
		{"too deep", x.ID, b.ID, 0, ErrTooDeep}, // X at depth 3 with a child at 4
		{"into Needs approval", x.ID, f.approvals, 0, ErrApprovalsHoldsNothingElse},
		{"unknown parent", x.ID, 9999, 0, ErrNoFolder},
		{"unknown folder", 9999, f.root, 0, ErrNoFolder},
		{"the root", f.root, x.ID, 0, ErrRootFixed},
		{"Needs approval", f.approvals, x.ID, 0, ErrApprovalsFixed},
		{"duplicate in the new parent", dup.ID, a.ID, 0, ErrDuplicateTitle},
		{"negative position", x.ID, f.root, -1, ErrBadPosition},
	}
	for _, c := range cases {
		_, _, err := f.s.Move(f.ctx, c.id, c.parent, c.pos, rev)
		assert.ErrorIs(t, err, c.want, c.name)
	}
	f.unchanged(before)

	// A leaf fits at depth 3.
	_, _, err := f.s.Move(f.ctx, dup.ID, c.ID, 0, rev)
	assert.ErrorIs(t, err, ErrTooDeep, "under C would be depth 4")
	leaf := f.create("Leaf", 0)
	_, _, err = f.s.Move(f.ctx, leaf.ID, b.ID, 0, f.rev())
	assert.NoError(t, err)
}

// --- delete refusals -------------------------------------------------------

func TestDelete_Refusals(t *testing.T) {
	f := newFixture(t)
	before := f.tree()
	_, _, err := f.s.Delete(f.ctx, f.root, before.Revision)
	assert.ErrorIs(t, err, ErrRootFixed)
	assert.EqualError(t, err, "the Inbox folder can't be changed")
	_, _, err = f.s.Delete(f.ctx, f.approvals, before.Revision)
	assert.ErrorIs(t, err, ErrApprovalsFixed)
	assert.EqualError(t, err, "Needs approval can't be moved, renamed, hidden or deleted")
	_, _, err = f.s.Delete(f.ctx, 9999, before.Revision)
	assert.ErrorIs(t, err, ErrNoFolder)
	f.unchanged(before)
}

// --- route -----------------------------------------------------------------

func TestRoute_ExistingFolderAndBackToRoot(t *testing.T) {
	f := newFixture(t)
	release := f.create("Release", 0)
	a := f.automation("acme-digest", "")
	b := f.automation("acme-weekly", "")
	var hashBefore string
	require.NoError(t, f.d.QueryRow(`SELECT approval_hash || '|' || updated_at FROM automations WHERE id = ?`, a).Scan(&hashBefore))

	_, _, created, err := f.s.Route(f.ctx, b, RouteRequest{FolderID: &release.ID, ExpectRevision: f.rev()})
	require.NoError(t, err)
	assert.False(t, created)
	_, got, _, err := f.s.Route(f.ctx, a, RouteRequest{FolderID: &release.ID, ExpectRevision: f.rev()})
	require.NoError(t, err)
	assert.Equal(t, release.ID, got.ID)
	assert.Equal(t, []int64{a, b}, got.AutomationIDs, "ascending")
	out := f.output(a, nil)
	assert.Equal(t, release.ID, f.artifactFolder(out))

	var hashAfter string
	require.NoError(t, f.d.QueryRow(`SELECT approval_hash || '|' || updated_at FROM automations WHERE id = ?`, a).Scan(&hashAfter))
	assert.Equal(t, hashBefore, hashAfter, "a route never touches the automation")

	tree, got, _, err := f.s.Route(f.ctx, a, RouteRequest{FolderID: &f.root, ExpectRevision: f.rev()})
	require.NoError(t, err)
	assert.Equal(t, []int64{a}, got.AutomationIDs, "a route to the root stays a row")
	rel, _ := tree.find(release.ID)
	assert.Equal(t, []int64{b}, rel.AutomationIDs)
	assert.Equal(t, f.root, f.artifactFolder(out))
}

func TestRoute_NewTitleCreatesFolderAndRoute(t *testing.T) {
	f := newFixture(t)
	parent := f.create("Work", 0)
	a := f.automation("acme-digest", "")
	tree, got, created, err := f.s.Route(f.ctx, a, RouteRequest{
		NewTitle: " Release ", NewIcon: "flag", ParentID: &parent.ID, ExpectRevision: f.rev(),
	})
	require.NoError(t, err)
	assert.True(t, created)
	assert.Equal(t, "Release", got.Title)
	assert.Equal(t, "release", got.Slug)
	assert.Equal(t, "flag", got.Icon)
	assert.Equal(t, []int64{a}, got.AutomationIDs)
	assert.Equal(t, int64(3), tree.Revision, "one write, one revision")
	assert.Equal(t, []string{"Release"}, f.childTitles(parent.ID))

	// The new folder's checks apply: a duplicate refuses the whole write.
	before := f.tree()
	_, _, _, err = f.s.Route(f.ctx, a, RouteRequest{NewTitle: "release", ParentID: &parent.ID, ExpectRevision: before.Revision})
	assert.ErrorIs(t, err, ErrDuplicateTitle)
	f.unchanged(before)
}

func TestRoute_NewTitleForUnknownAutomationCreatesNoFolder(t *testing.T) {
	f := newFixture(t)
	before := f.tree()
	foldersBefore := f.count(`SELECT COUNT(*) FROM inbox_folders`)
	_, _, _, err := f.s.Route(f.ctx, 4242, RouteRequest{NewTitle: "Release", ExpectRevision: before.Revision})
	assert.ErrorIs(t, err, ErrNoAutomation)
	assert.EqualError(t, err, "no automation 4242")
	assert.Equal(t, foldersBefore, f.count(`SELECT COUNT(*) FROM inbox_folders`))
	assert.Equal(t, before.Revision, f.rev())
	f.unchanged(before)
}

func TestRoute_NeedsApprovalRules(t *testing.T) {
	f := newFixture(t)
	release := f.create("Release", 0)
	owner := f.automation("acme-digest", "")
	builtin := f.automation("needs-approval", needsApprovalBuiltinID)
	other := f.automation("morning-brief", "morning-brief")

	before := f.tree()
	rev := before.Revision
	_, _, _, err := f.s.Route(f.ctx, owner, RouteRequest{FolderID: &f.approvals, ExpectRevision: rev})
	assert.ErrorIs(t, err, ErrApprovalsHoldsNothingElse, "it holds only its built-in")
	_, _, _, err = f.s.Route(f.ctx, other, RouteRequest{FolderID: &f.approvals, ExpectRevision: rev})
	assert.ErrorIs(t, err, ErrApprovalsHoldsNothingElse, "another built-in neither")
	_, _, _, err = f.s.Route(f.ctx, builtin, RouteRequest{FolderID: &release.ID, ExpectRevision: rev})
	assert.ErrorIs(t, err, ErrApprovalsRouteFixed)
	assert.EqualError(t, err, "Needs approval's automation stays in Needs approval")
	_, _, _, err = f.s.Route(f.ctx, builtin, RouteRequest{FolderID: &f.root, ExpectRevision: rev})
	assert.ErrorIs(t, err, ErrApprovalsRouteFixed)
	_, _, _, err = f.s.Route(f.ctx, builtin, RouteRequest{NewTitle: "Elsewhere", ExpectRevision: rev})
	assert.ErrorIs(t, err, ErrApprovalsRouteFixed)
	_, _, _, err = f.s.Route(f.ctx, owner, RouteRequest{NewTitle: "Inside", ParentID: &f.approvals, ExpectRevision: rev})
	assert.ErrorIs(t, err, ErrApprovalsHoldsNothingElse)
	f.unchanged(before)

	_, got, _, err := f.s.Route(f.ctx, builtin, RouteRequest{FolderID: &f.approvals, ExpectRevision: rev})
	require.NoError(t, err)
	assert.Equal(t, []int64{builtin}, got.AutomationIDs)
}

func TestRoute_TargetShape(t *testing.T) {
	f := newFixture(t)
	release := f.create("Release", 0)
	a := f.automation("acme-digest", "")
	before := f.tree()
	rev := before.Revision
	cases := []struct {
		name string
		req  RouteRequest
		want error
	}{
		{"neither", RouteRequest{ExpectRevision: rev}, ErrRouteTarget},
		{"both", RouteRequest{FolderID: &release.ID, NewTitle: "X", ExpectRevision: rev}, ErrRouteTarget},
		{"icon with a folder", RouteRequest{FolderID: &release.ID, NewIcon: "flag", ExpectRevision: rev}, ErrRouteTarget},
		{"parent with a folder", RouteRequest{FolderID: &release.ID, ParentID: &f.root, ExpectRevision: rev}, ErrRouteTarget},
		{"unknown folder", RouteRequest{FolderID: ptr(int64(9999)), ExpectRevision: rev}, ErrNoFolder},
		{"bad new title", RouteRequest{NewTitle: "a\nb", ExpectRevision: rev}, ErrBadTitle},
		{"bad new icon", RouteRequest{NewTitle: "X", NewIcon: "nope", ExpectRevision: rev}, ErrUnknownIcon},
		{"unknown automation", RouteRequest{FolderID: &release.ID, ExpectRevision: rev}, nil},
	}
	for _, c := range cases {
		id := a
		if c.want == nil {
			id, c.want = 4242, ErrNoAutomation
		}
		_, _, _, err := f.s.Route(f.ctx, id, c.req)
		assert.ErrorIs(t, err, c.want, c.name)
	}
	f.unchanged(before)
}

// --- compare-and-set -------------------------------------------------------

func TestWrites_StaleRevisionWritesNothing(t *testing.T) {
	f := newFixture(t)
	release := f.create("Release", 0)
	a := f.automation("acme-digest", "")
	before := f.tree()
	stale := before.Revision - 1
	writes := map[string]func() error{
		"create": func() error {
			_, _, err := f.s.Create(f.ctx, CreateRequest{Title: "X", ExpectRevision: stale})
			return err
		},
		"update": func() error {
			_, _, err := f.s.Update(f.ctx, release.ID, UpdateRequest{Title: ptr("Y"), ExpectRevision: stale})
			return err
		},
		"move":   func() error { _, _, err := f.s.Move(f.ctx, release.ID, f.root, 5, stale); return err },
		"delete": func() error { _, _, err := f.s.Delete(f.ctx, release.ID, stale); return err },
		"route": func() error {
			_, _, _, err := f.s.Route(f.ctx, a, RouteRequest{FolderID: &release.ID, ExpectRevision: stale})
			return err
		},
	}
	for name, write := range writes {
		err := write()
		assert.ErrorIs(t, err, ErrRevisionConflict, name)
		var dbConflict *db.ErrInboxRevisionConflict
		assert.True(t, errors.As(err, &dbConflict), name)
		assert.EqualError(t, err, fmt.Sprintf("the Inbox menu changed — reload it and try again (revision %d, you had %d)",
			before.Revision, stale), name)
	}
	f.unchanged(before)
}

func TestWrites_MissingRevisionRefusedBeforeAnyRead(t *testing.T) {
	f := newFixture(t)
	_, _, err := f.s.Create(f.ctx, CreateRequest{Title: "X"})
	assert.ErrorIs(t, err, ErrRevisionRequired)
	_, _, err = f.s.Update(f.ctx, 9999, UpdateRequest{Title: ptr("Y")})
	assert.ErrorIs(t, err, ErrRevisionRequired, "refused before the id is looked up")
	_, _, err = f.s.Move(f.ctx, 9999, f.root, 0, 0)
	assert.ErrorIs(t, err, ErrRevisionRequired)
	_, _, err = f.s.Delete(f.ctx, 9999, 0)
	assert.ErrorIs(t, err, ErrRevisionRequired)
	_, _, _, err = f.s.Route(f.ctx, 9999, RouteRequest{NewTitle: "X"})
	assert.ErrorIs(t, err, ErrRevisionRequired)
	assert.EqualError(t, err, "--expect-revision is required")

	// A closed database proves no read happened.
	require.NoError(t, f.d.Close())
	_, _, err = f.s.Delete(f.ctx, 1, 0)
	assert.ErrorIs(t, err, ErrRevisionRequired)
}

// TestWrites_TwoWritersRaceOneWins opens one database file twice (two
// processes' handles) and races the same expected revision: exactly one
// write lands, the other is a conflict, and the tree holds one new folder.
func TestWrites_TwoWritersRaceOneWins(t *testing.T) {
	path := filepath.Join(t.TempDir(), "watchtower.db")
	var stores [2]*Store
	for i := range stores {
		d, err := db.Open(path)
		require.NoError(t, err)
		t.Cleanup(func() { _ = d.Close() })
		stores[i] = NewStore(d)
	}
	ctx := context.Background()
	start := make(chan struct{})
	errs := make([]error, 2)
	var wg sync.WaitGroup
	for i, s := range stores {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			_, _, errs[i] = s.Create(ctx, CreateRequest{Title: fmt.Sprintf("Racer %d", i), ExpectRevision: 1})
		}()
	}
	close(start)
	wg.Wait()

	wins, conflicts := 0, 0
	for _, err := range errs {
		switch {
		case err == nil:
			wins++
		case errors.Is(err, ErrRevisionConflict):
			conflicts++
		default:
			t.Fatalf("unexpected error: %v", err)
		}
	}
	assert.Equal(t, 1, wins)
	assert.Equal(t, 1, conflicts)
	tree, err := stores[0].List(ctx)
	require.NoError(t, err)
	assert.Equal(t, int64(2), tree.Revision)
	assert.Len(t, tree.Folders, 3)
}

// --- list ------------------------------------------------------------------

func TestList_FreshTree(t *testing.T) {
	f := newFixture(t)
	tree := f.tree()
	assert.Equal(t, int64(1), tree.Revision)
	require.Len(t, tree.Folders, 2)
	assert.Equal(t, kindRoot, tree.Folders[0].Kind)
	assert.Nil(t, tree.Folders[0].ParentID)
	assert.Equal(t, kindApprovals, tree.Folders[1].Kind)
	assert.Equal(t, []int64{}, tree.Folders[0].AutomationIDs, "never nil")
}

func TestSlug_Base(t *testing.T) {
	cases := map[string]string{
		"Release":         "release",
		"--Release--":     "release",
		"Q3 Launch":       "q3-launch",
		"a  b":            "a-b",
		"Ünïcode Straße":  "n-code-stra-e",
		"🚀":               "folder",
		"Release 2026/11": "release-2026-11",
	}
	for title, want := range cases {
		assert.Equal(t, want, baseSlug(title), title)
	}
}
