package sessioncleanup

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// Source §2a of the auto cleanup spec (2026-11-10): the worktrees Claude
// Code's subagent records name.

// otherUUID is a Claude Code session of another row.
const otherUUID = "5d4c3b2a-1f0e-4d9c-8b7a-6f5e4d3c2b1a"

// projectsDir is the fixture's Claude Code projects directory.
func (f *fixture) projectsDir() string { return f.projects }

// transcript writes uuid's main transcript in the fixture's project folder.
func (f *fixture) transcript(uuid string) {
	writeFile(f.t, filepath.Join(f.projectsDir(), "-tmp-acme", uuid+".jsonl"), "{}\n")
}

// subagentRecord writes uuid's transcript and its subagents/<id>.meta.json
// with raw as the content; it returns the record's path.
func (f *fixture) subagentRecord(uuid, id, raw string) string {
	f.t.Helper()
	f.transcript(uuid)
	path := filepath.Join(f.projectsDir(), "-tmp-acme", uuid, "subagents", id+".meta.json")
	writeFile(f.t, path, raw)
	return path
}

// recordJSON is a record of a subagent started in the worktree at root on
// branch.
func recordJSON(t *testing.T, root, branch string) string {
	t.Helper()
	raw, err := json.Marshal(map[string]any{
		"agentType": "general-purpose", "spawnedWithWorktree": true, "worktreePath": root,
		"worktreeBranch": branch, "toolUseId": "toolu_00000000000000000000000000", "finished": true,
	})
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// agentWorktree adds Claude Code's worktree of subagent id,
// <repo>/.claude/worktrees/<id>, on a new branch from main (merged).
func (f *fixture) agentWorktree(id, branch string) string {
	f.t.Helper()
	root := filepath.Join(f.repo, ".claude", "worktrees", id)
	gitIn(f.t, f.repo, "worktree", "add", "-q", "-b", branch, root, "main")
	return root
}

// bornAtFor makes the admin dir named base born at at; the others keep
// their real (stamp) birth.
func (f *fixture) bornAtFor(births map[string]time.Time) {
	f.birth = func(admin string) (time.Time, bool) {
		if at, ok := births[filepath.Base(admin)]; ok {
			return at, true
		}
		return stampBirth(admin)
	}
}

// newSubagentFixture is a claude row that alone owns testUUID, acquired 30
// minutes ago, with an empty projects directory.
func newSubagentFixture(t *testing.T) *fixture {
	t.Helper()
	f := newFixture(t)
	f.ownUUID(time.Now().Add(-30 * time.Minute))
	return f
}

func wantNote(t *testing.T, p Plan, want bool) {
	t.Helper()
	if got := slices.Contains(p.Notes, NoteSubagentRecordsUnreadable); got != want {
		t.Fatalf("notes = %v, want the subagent note: %v", p.Notes, want)
	}
}

func TestProj18_SubagentWorktreeIsTheSessions(t *testing.T) {
	f := newSubagentFixture(t)
	root := f.agentWorktree("agent-a1", "worktree-agent-a1")
	f.subagentRecord(testUUID, "agent-a1", recordJSON(t, root, "worktree-agent-a1"))

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+root, ActionRemove, "")
	wantItem(t, p, "branch:worktree-agent-a1", ActionRemove, "")
	wantNote(t, p, false)

	// A worktree born before this row acquired the uuid is not adopted.
	f.ownUUID(time.Now().Add(30 * time.Minute))
	p = f.plan(Request{})
	if hasItem(p, "worktree:"+root) || hasItem(p, "branch:worktree-agent-a1") {
		t.Fatalf("a worktree older than the uuid's acquisition was adopted: %+v", p.Items)
	}
}

// The committed sample has the shape of a real record (neutral values):
// read through the planner, it adopts its worktree and branch.
func TestScratchMetaSampleAdopts(t *testing.T) {
	f := newSubagentFixture(t)
	root := f.agentWorktree("agent-a0123456789abcdef", "worktree-agent-a0123456789abcdef")
	raw, err := os.ReadFile(filepath.Join("testdata", "subagent-meta-sample.json"))
	if err != nil {
		t.Fatal(err)
	}
	sample := strings.NewReplacer("{{worktree_path}}", root,
		"{{worktree_branch}}", "worktree-agent-a0123456789abcdef").Replace(string(raw))
	f.subagentRecord(testUUID, "agent-a0123456789abcdef", sample)

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+root, ActionRemove, "")
	wantItem(t, p, "branch:worktree-agent-a0123456789abcdef", ActionRemove, "")
	wantNote(t, p, false)
}

// Claude Code renamed the record's keys: the worktree named after the agent
// is not adopted, and the plan says the records could not be read.
func TestSubagentRecordKeysRenamedGivesNote(t *testing.T) {
	f := newSubagentFixture(t)
	root := f.agentWorktree("agent-a2", "worktree-agent-a2")
	f.subagentRecord(testUUID, "agent-a2",
		`{"spawnedWithWorktree":true,"worktree_path":"`+root+`","worktree_branch":"worktree-agent-a2"}`)

	p := f.plan(Request{})
	if hasItem(p, "worktree:"+root) || hasItem(p, "branch:worktree-agent-a2") {
		t.Fatalf("a worktree its record does not name was adopted: %+v", p.Items)
	}
	wantNote(t, p, true)
}

// Records stopped landing where the cleanup reads them: older records stay,
// and an agent-<id> worktree born after the newest of them has none.
func TestSubagentRecordsMovedGivesNote(t *testing.T) {
	f := newSubagentFixture(t)
	f.transcript(testUUID)
	old := f.subagentRecord(otherUUID, "agent-aold", recordJSON(t, "/tmp/acme/elsewhere", "feat/elsewhere"))
	past := time.Now().Add(-2 * time.Hour)
	if err := os.Chtimes(old, past, past); err != nil {
		t.Fatal(err)
	}
	root := f.agentWorktree("agent-anew", "worktree-agent-anew")

	p := f.plan(Request{})
	if hasItem(p, "worktree:"+root) {
		t.Fatalf("a worktree with no record was adopted: %+v", p.Items)
	}
	wantNote(t, p, true)

	// A record of it anywhere under the projects directory (another
	// session's subagent) says nothing.
	f.subagentRecord(otherUUID, "agent-anew", recordJSON(t, root, "worktree-agent-anew"))
	if err := os.Chtimes(filepath.Join(filepath.Dir(old), "agent-anew.meta.json"), past, past); err != nil {
		t.Fatal(err)
	}
	wantNote(t, f.plan(Request{}), false)
}

// An old session's transcript was pruned (its records with it) while later
// subagents' records exist: normal, no note, nothing adopted.
func TestPrunedTranscriptGivesNoNote(t *testing.T) {
	f := newSubagentFixture(t)
	root := f.agentWorktree("agent-apruned", "worktree-agent-apruned")
	f.bornAtFor(map[string]time.Time{"agent-apruned": time.Now().Add(-20 * time.Minute)})
	later := f.subagentRecord(otherUUID, "agent-alater", recordJSON(t, "/tmp/acme/later", "feat/later"))
	recent := time.Now().Add(-5 * time.Minute)
	if err := os.Chtimes(later, recent, recent); err != nil {
		t.Fatal(err)
	}

	p := f.plan(Request{})
	if hasItem(p, "worktree:"+root) {
		t.Fatalf("a worktree with no record was adopted: %+v", p.Items)
	}
	wantNote(t, p, false)
}

// A worktree born after the row's terminal ended is not the row's: its
// missing record says nothing about this row.
func TestSubagentWorktreeBornAfterRowEndedGivesNoNote(t *testing.T) {
	f := newSubagentFixture(t)
	f.transcript(testUUID)
	f.agentWorktree("agent-alate", "worktree-agent-alate")

	f.store.session.Ended = time.Now().Add(-10 * time.Minute)
	wantNote(t, f.plan(Request{}), false)

	// Control: the same worktree while the row lives gives the note.
	f.store.session.Ended = time.Time{}
	wantNote(t, f.plan(Request{}), true)
	// So does a live terminal of a row being deleted (no upper bound).
	f.store.session.Ended = time.Now().Add(-10 * time.Minute)
	wantNote(t, f.plan(Request{LiveSessions: []int64{testSession}}), true)
}

func TestSubagentMetaUnreadableFailsPlan(t *testing.T) {
	cases := map[string]func(f *fixture, path string){
		"not json": func(f *fixture, path string) { writeFile(f.t, path, "{not json") },
		"unreadable": func(f *fixture, path string) {
			if os.Geteuid() == 0 {
				f.t.Skip("root reads every file")
			}
			if err := os.Chmod(path, 0); err != nil {
				f.t.Fatal(err)
			}
			f.t.Cleanup(func() { _ = os.Chmod(path, 0o644) })
		},
		"a symlink": func(f *fixture, path string) {
			target := filepath.Join(f.base, "target.json")
			writeFile(f.t, target, "{}")
			if err := os.Remove(path); err != nil {
				f.t.Fatal(err)
			}
			if err := os.Symlink(target, path); err != nil {
				f.t.Fatal(err)
			}
		},
	}
	for name, breakIt := range cases {
		t.Run(name, func(t *testing.T) {
			f := newSubagentFixture(t)
			root := f.agentWorktree("agent-a3", "worktree-agent-a3")
			path := f.subagentRecord(testUUID, "agent-a3", recordJSON(t, root, "worktree-agent-a3"))
			breakIt(f, path)
			if res, err := PlanResult(context.Background(), f.deps(), Request{SessionID: testSession}); err == nil {
				t.Fatalf("PlanResult = %+v, want an error", res.Plan.Items)
			}
		})
	}
}

func TestProjectsDirMissingGivesNote(t *testing.T) {
	f := newSubagentFixture(t)
	f.projects = filepath.Join(f.base, "no-such-dir")
	wantNote(t, f.plan(Request{}), true)

	// The home directory is unknown: the same.
	f.projects = ""
	wantNote(t, f.plan(Request{}), true)

	// A row with no counted uuid reads nothing and notes nothing.
	f.store.uuidOwners[testUUID] = []int64{testSession, testSession + 1}
	wantNote(t, f.plan(Request{}), false)
}

// Rewrite of the command-row guard (owner, ask #1259): an adopted item with
// unpushed commits is kept, whatever source adopted it — a subagent's
// worktree (§2a) and a branch the subagent created and left in it (§2c).
func TestProj18_SubagentWorktreeUnpushedIsKept(t *testing.T) {
	f := newSubagentFixture(t)
	root := f.agentWorktree("agent-a4", "worktree-agent-a4")
	f.commit(root, "local.txt", "only here\n")
	f.subagentRecord(testUUID, "agent-a4", recordJSON(t, root, "worktree-agent-a4"))
	gitIn(t, root, "checkout", "-q", "-b", "feat/alone")
	f.commit(root, "alone.txt", "only here too\n")
	gitIn(t, root, "checkout", "-q", "worktree-agent-a4")

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+root, ActionKeep, ReasonUnpushedCommits)
	wantItem(t, p, "branch:worktree-agent-a4", ActionKeep, ReasonCheckedOut)
	wantItem(t, p, "branch:feat/alone", ActionKeep, ReasonUnpushedCommits)
}

// A record naming a worktree of another repository names nothing here: not
// its worktree, and not its branch, though a worktree of the planned
// repository has a branch of that name.
func TestProj18_SubagentRecordFromOtherRepoNamesNothing(t *testing.T) {
	f := newSubagentFixture(t)
	otherRepo := filepath.Join(f.base, "other")
	gitIn(t, f.base, "init", "-q", "-b", "main", "other")
	f.commit(otherRepo, "README.md", "other\n")
	otherWT := filepath.Join(otherRepo, ".claude", "worktrees", "agent-b1")
	gitIn(t, otherRepo, "worktree", "add", "-q", "-b", "worktree-agent-b1", otherWT, "main")
	f.subagentRecord(testUUID, "agent-b1", recordJSON(t, otherWT, "worktree-agent-b1"))
	f.subagentRecord(testUUID, "agent-b2", recordJSON(t, filepath.Join(f.base, "gone"), "worktree-agent-b2"))
	mine := f.pushedWork("wt-mine", "worktree-agent-b1")
	mine2 := f.pushedWork("wt-mine2", "worktree-agent-b2")

	p := f.plan(Request{})
	for _, key := range []string{"worktree:" + mine, "worktree:" + mine2, "worktree:" + otherWT,
		"branch:worktree-agent-b1", "branch:worktree-agent-b2"} {
		if hasItem(p, key) {
			t.Fatalf("%s was adopted through another repository's record: %+v", key, p.Items)
		}
	}
	wantNote(t, p, false)
}

// A Codex row has no Claude session files: §2a and §2b adopt nothing and
// note nothing, while §2c (git only) still names its branches.
func TestClaudeSessionFilesCapGatesSubagentAndScratch(t *testing.T) {
	f := newSubagentFixture(t)
	useScratchBases(t, f.base)
	sub := f.agentWorktree("agent-a5", "worktree-agent-a5")
	f.subagentRecord(testUUID, "agent-a5", recordJSON(t, sub, "worktree-agent-a5"))
	lane := f.scratchWorktree("lane", "feat/lane")
	wt := f.worktree("wt", "feat/wt")
	f.record(wt, "feat/wt")
	gitIn(t, wt, "checkout", "-q", "-b", "mine")
	gitIn(t, wt, "checkout", "-q", "feat/wt")

	claude := f.plan(Request{})
	wantItem(t, claude, "worktree:"+sub, ActionRemove, "")
	wantItem(t, claude, "worktree:"+lane, ActionRemove, "")
	wantItem(t, claude, "branch:mine", ActionRemove, "")
	wantNote(t, claude, false)

	f.store.session.Kind = "codex"
	codex := f.plan(Request{})
	for _, key := range []string{"worktree:" + sub, "worktree:" + lane, "branch:worktree-agent-a5", "branch:feat/lane"} {
		if hasItem(codex, key) {
			t.Fatalf("a codex row adopted %s: %+v", key, codex.Items)
		}
	}
	wantItem(t, codex, "branch:mine", ActionRemove, "")
	wantNote(t, codex, false)

	// The projects directory gone: a claude row notes it, a codex row
	// never reads it.
	f.projects = filepath.Join(f.base, "no-such-dir")
	wantNote(t, f.plan(Request{}), false)
	f.store.session.Kind = "claude"
	wantNote(t, f.plan(Request{}), true)
}

// The projects path exists but is a file: no records can be read there.
func TestProjectsDirIsAFileGivesNote(t *testing.T) {
	f := newSubagentFixture(t)
	f.projects = filepath.Join(f.base, "projects-file")
	writeFile(t, f.projects, "not a folder\n")
	wantNote(t, f.plan(Request{}), true)
}

// A folder of another project that cannot be read hides its records: the
// worktree with no record stays unadopted and the plan carries the note,
// it does not fail. A counted uuid's own unreadable record still fails it
// (TestSubagentMetaUnreadableFailsPlan).
func TestUnreadableOtherProjectFolderGivesNote(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads every folder")
	}
	for name, hidden := range map[string]string{
		"a session folder (the freshness scan)":    filepath.Join("-tmp-other", otherUUID),
		"a project folder (the transcript search)": "-tmp-other",
	} {
		t.Run(name, func(t *testing.T) {
			f := newSubagentFixture(t)
			f.transcript(testUUID)
			root := f.agentWorktree("agent-anew", "worktree-agent-anew")
			// A fresh record of another session: records still land here.
			f.subagentRecord("6e5d4c3b-2a1f-4e0d-9c8b-7a6f5e4d3c2b", "agent-afresh",
				recordJSON(t, "/tmp/acme/fresh", "feat/fresh"))
			wantNote(t, f.plan(Request{}), false)

			dir := filepath.Join(f.projects, hidden)
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.Chmod(dir, 0); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })
			p := f.plan(Request{})
			if hasItem(p, "worktree:"+root) {
				t.Fatalf("a worktree with no record was adopted: %+v", p.Items)
			}
			wantNote(t, p, true)
		})
	}
}

// The apply removes the subagent's worktree first; its record then names a
// worktree that is no longer listed, and no ledger row names the branch:
// the branch still goes on the plan's evidence.
func TestApplyRemovesSubagentBranchAfterItsWorktree(t *testing.T) {
	f := newSubagentFixture(t)
	root := f.agentWorktree("agent-a6", "worktree-agent-a6")
	f.subagentRecord(testUUID, "agent-a6", recordJSON(t, root, "worktree-agent-a6"))

	res := f.apply(Request{}, nil, nil)
	wantResultItem(t, res, "worktree:"+root, ActionRemove, "", true)
	wantResultItem(t, res, "branch:worktree-agent-a6", ActionRemove, "", true)
	if f.branchExists("worktree-agent-a6") {
		t.Fatal("the subagent's branch was left behind after its worktree went")
	}
}

func TestClaudeProjectsDirNeedsAnAbsoluteDir(t *testing.T) {
	for dir, want := range map[string]string{
		"/home/acme/.claude": "/home/acme/.claude/projects",
		".claude":            "",
		"":                   "",
	} {
		if got := ClaudeProjectsDir(dir); got != want {
			t.Errorf("ClaudeProjectsDir(%q) = %q, want %q", dir, got, want)
		}
	}
}
