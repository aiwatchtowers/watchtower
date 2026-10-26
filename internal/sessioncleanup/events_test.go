package sessioncleanup

import (
	"context"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// event is one observer call.
type event struct {
	kind  string // listed, checked, sized, removing, removed
	key   string
	item  Item
	items []Item
	bytes int64
	known bool
}

// recorder records every observer call in order.
type recorder struct {
	mu     sync.Mutex
	events []event
}

func (r *recorder) add(e event) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, e)
}

func (r *recorder) Listed(items []Item) {
	r.add(event{kind: "listed", items: append([]Item(nil), items...)})
}
func (r *recorder) Checked(it Item) { r.add(event{kind: "checked", key: it.Key, item: it}) }
func (r *recorder) Sized(key string, bytes int64, known bool) {
	r.add(event{kind: "sized", key: key, bytes: bytes, known: known})
}
func (r *recorder) Removing(key string) { r.add(event{kind: "removing", key: key}) }
func (r *recorder) Removed(it Item)     { r.add(event{kind: "removed", key: it.Key, item: it}) }

func (r *recorder) of(kind string) []event {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []event
	for _, e := range r.events {
		if e.kind == kind {
			out = append(out, e)
		}
	}
	return out
}

// fixedSizer answers every root with 42 bytes.
type fixedSizer struct{}

func (fixedSizer) Size(context.Context, string, time.Duration) (int64, bool) { return 42, true }

func (f *fixture) planWith(r Request, adjust func(*Deps)) Result {
	f.t.Helper()
	if r.SessionID == 0 && !r.Sweep {
		r.SessionID = testSession
	}
	if r.Sweep {
		r.WorkbenchID = testWorkbench
	}
	d := f.deps()
	if adjust != nil {
		adjust(&d)
	}
	res, err := PlanResult(context.Background(), d, r)
	if err != nil {
		f.t.Fatalf("PlanResult: %v", err)
	}
	return res
}

// sweepFixture: a removable worktree, a kept one (unpushed commit) and a
// branch with no worktree.
func sweepFixture(t *testing.T) (f *fixture, removable, kept string) {
	t.Helper()
	f = newFixture(t)
	removable = f.pushedWork("wt-a", "feat/a")
	kept = f.worktree("wt-k", "feat/k")
	f.commit(kept, "local.txt", "only here\n")
	gitIn(t, f.repo, "branch", "feat/lone", "main")
	return f, removable, kept
}

func withSizeAndBundles(d *Deps) {
	d.Sizer, d.LS = fixedSizer{}, &fakeLS{log: &opLog{}}
}

func TestObserverOrderInASweep(t *testing.T) {
	t.Parallel()
	f, removable, _ := sweepFixture(t)
	rec := &recorder{}
	res := f.planWith(Request{Sweep: true, Observer: rec}, withSizeAndBundles)

	if len(rec.events) == 0 || rec.events[0].kind != "listed" || len(rec.of("listed")) != 1 {
		t.Fatalf("listed is not the one first event: %+v", rec.events)
	}
	listed := map[string]Item{}
	for _, it := range rec.events[0].items {
		if it.Action != "" {
			t.Fatalf("listed item %s carries action %q", it.Key, it.Action)
		}
		listed[it.Key] = it
	}
	lastWorktreeChecked, firstSized := -1, len(rec.events)
	for i, e := range rec.events {
		switch e.kind {
		case "checked":
			_, inListed := listed[e.key]
			bundleOf := e.item.Kind == KindLsreg && e.item.Worktree != "" && hasKey(listed, "worktree:"+e.item.Worktree)
			branchOf := e.item.Kind == KindBranch && listedWorktreeHasBranch(listed, e.item.Name)
			if !inListed && !bundleOf && !branchOf {
				t.Fatalf("checked %s is neither listed nor part of a listed worktree", e.key)
			}
			if e.item.Action == "" {
				t.Fatalf("checked %s has no action", e.key)
			}
			if e.item.Kind == KindWorktree {
				lastWorktreeChecked = i
			}
		case "sized":
			firstSized = min(firstSized, i)
			if it := findItem(t, res.Plan, e.key); it.Kind != KindWorktree || it.Action != ActionRemove {
				t.Fatalf("sized %s is not a worktree to remove: %+v", e.key, it)
			}
		}
	}
	if len(rec.of("sized")) != 1 || rec.of("sized")[0].key != "worktree:"+removable || firstSized < lastWorktreeChecked {
		t.Fatalf("sized events = %+v (last worktree checked at %d)", rec.of("sized"), lastWorktreeChecked)
	}
	// The final items are the last-seen versions.
	last := map[string]Item{}
	for _, e := range rec.events {
		switch e.kind {
		case "checked":
			last[e.key] = e.item
		case "sized":
			it := last[e.key]
			it.Bytes, it.BytesKnown = e.bytes, e.known
			last[e.key] = it
		}
	}
	if len(last) != len(res.Plan.Items) {
		t.Fatalf("observed %d items, plan has %d: %+v", len(last), len(res.Plan.Items), res.Plan.Items)
	}
	for _, it := range res.Plan.Items {
		if !reflect.DeepEqual(last[it.Key], it) {
			t.Fatalf("%s: observed %+v, plan %+v", it.Key, last[it.Key], it)
		}
	}
	if len(rec.of("removing")) != 0 || len(rec.of("removed")) != 0 {
		t.Fatal("a plan reported removals")
	}
}

func hasKey(m map[string]Item, k string) bool { _, ok := m[k]; return ok }

func listedWorktreeHasBranch(listed map[string]Item, branch string) bool {
	for _, it := range listed {
		if it.Kind == KindWorktree && it.Branch == branch {
			return true
		}
	}
	return false
}

func TestListedHoldsWorktreesAndBranchOnlyRows(t *testing.T) {
	t.Parallel()
	f, removable, kept := sweepFixture(t)
	rec := &recorder{}
	f.planWith(Request{Sweep: true, Observer: rec}, withSizeAndBundles)

	var keys []string
	for _, it := range rec.events[0].items {
		keys = append(keys, it.Key)
	}
	want := []string{"worktree:" + removable, "worktree:" + kept, "branch:feat/lone"}
	if !reflect.DeepEqual(keys, want) {
		t.Fatalf("listed = %v, want %v", keys, want)
	}
	checked := map[string]bool{}
	for _, e := range rec.of("checked") {
		checked[e.key] = true
	}
	if !checked["branch:feat/a"] {
		t.Fatal("the removable worktree's branch never arrived")
	}
	if checked["branch:feat/k"] {
		t.Fatal("the kept worktree's branch arrived")
	}
	if !checked["lsreg:"+filepath.Join(removable, "Build", "App.app")] {
		t.Fatal("the removable worktree's bundle never arrived")
	}
}

// TestListedInSessionMode: the session's worktree and its observed
// branch-only rows; its worktree's branch rides with the worktree.
func TestListedInSessionMode(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	gitIn(t, f.repo, "branch", "feat/lone", "main")
	rec := &recorder{}
	f.planWith(Request{Observer: rec, DeclaredBranches: []string{"feat/lone"}}, nil)

	var keys []string
	for _, it := range rec.events[0].items {
		keys = append(keys, it.Key)
	}
	want := []string{"worktree:" + root, "branch:feat/lone"}
	if !reflect.DeepEqual(keys, want) {
		t.Fatalf("listed = %v, want %v", keys, want)
	}
}

func TestApplyReportsEachItem(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	a, b := f.pushedWork("wt-a", "feat/a"), f.pushedWork("wt-b", "feat/b")
	f.record(a, "feat/a")
	f.record(b, "feat/b")
	procs := &dyingProcs{}
	// The first re-check's scan: wt-b gains an untracked file after the
	// apply's evaluation, so its own re-check keeps it.
	procs.onScan = func(n int) {
		if n == 2 {
			writeFile(t, filepath.Join(b, "late.txt"), "new\n")
		}
	}
	rec := &recorder{}
	res := f.apply(Request{Observer: rec}, []string{"worktree:" + a, "worktree:" + b},
		func(d *Deps) { d.Procs = procs })

	var order []string
	for _, e := range rec.events {
		if e.kind == "removing" || e.kind == "removed" {
			order = append(order, e.kind+" "+e.key)
		}
	}
	want := []string{
		"removing worktree:" + a, "removed worktree:" + a,
		"removing worktree:" + b, "removed worktree:" + b,
	}
	if !reflect.DeepEqual(order, want) {
		t.Fatalf("apply events = %v, want %v", order, want)
	}
	removed := rec.of("removed")
	if !removed[0].item.Done || removed[1].item.Done || removed[1].item.Reason != ReasonUncommittedChanges {
		t.Fatalf("removed items = %+v", removed)
	}
	wantResultItem(t, res, "worktree:"+b, ActionKeep, ReasonUncommittedChanges, false)
	// The re-checks report nothing: one listing, from the apply's own plan.
	if len(rec.of("listed")) != 1 {
		t.Fatalf("listed %d times", len(rec.of("listed")))
	}
}

func TestNilObserverChangesNothing(t *testing.T) {
	t.Parallel()
	f, _, _ := sweepFixture(t)
	without := f.planWith(Request{Sweep: true, Now: time.Unix(1_800_000_000, 0)}, withSizeAndBundles)
	with := f.planWith(Request{Sweep: true, Now: time.Unix(1_800_000_000, 0), Observer: &recorder{}},
		withSizeAndBundles)
	if !reflect.DeepEqual(without, with) {
		t.Fatalf("results differ:\n%+v\n%+v", without, with)
	}
	if !strings.Contains(without.Summary, "worktree") {
		t.Fatalf("summary = %q", without.Summary)
	}
}
