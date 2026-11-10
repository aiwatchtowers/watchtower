package coach

import (
	"bytes"
	"context"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/prompts"
)

// coach01State is every destination the coach can write, read back as the
// owner would see it: the three global texts, the spec reviewer's additions
// and the two files under the home folder.
func coach01State(t *testing.T, d dbs, home string) map[string]string {
	t.Helper()
	g, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	adds, err := d.ListPromptAdditions(prompts.SpecReview)
	require.NoError(t, err)
	state := map[string]string{
		"session": g.Session, "procedure": g.Procedure, "chat": g.Chat,
		"additions": joinAdditions(adds),
	}
	for _, name := range []string{"settings.json", "CLAUDE.md"} {
		b, err := os.ReadFile(filepath.Join(home, ".claude", name))
		require.NoError(t, err)
		state[name] = string(b)
	}
	return state
}

// COACH-01: nothing the coach proposes changes the owner's setup until the
// owner's Accept, and no destination is a repository file.
func TestCOACH01_NothingAppliedWithoutAccept(t *testing.T) {
	d := openDBs(t)
	home := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(home, ".claude"), 0o700))
	settings := "{\n  \"permissions\": {\n    \"allow\": [\n      \"Bash(ls:*)\"\n    ]\n  }\n}\n"
	require.NoError(t, os.WriteFile(filepath.Join(home, ".claude", "settings.json"), []byte(settings), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(home, ".claude", "CLAUDE.md"), []byte("Be kind.\n"), 0o600))
	require.NoError(t, d.SetOwnerInstruction(db.InstructionSession, "Run tests. Run lint.\nKeep commits small."))
	_, err := d.AddPromptAddition(prompts.SpecReview, "Do not flag naming choices.", 0, t0)
	require.NoError(t, err)

	before := coach01State(t, d, home)

	// The weekly pass: the model proposes a session, a chat and a prompt edit.
	gen := &countingGen{out: fixture(t, "propose_slots.json")}
	p := &Proposer{DB: d.DB, Gen: gen, Now: func() time.Time { return sigNow }, Logger: log.New(&bytes.Buffer{}, "", 0)}
	n, _, err := p.Run(context.Background(), proposeInputs())
	require.NoError(t, err)
	require.Equal(t, 3, n, "the proposals are stored")
	open, err := d.ListCoachProposals("open")
	require.NoError(t, err)
	require.Len(t, open, 3)

	assert.Equal(t, before, coach01State(t, d, home), "a stored proposal changes no destination")

	// Only Accept writes, and only its own destination.
	var chat db.CoachProposal
	for _, pr := range open {
		if pr.Destination == DestChat {
			chat = pr
		}
	}
	require.NotZero(t, chat.ID)
	require.NoError(t, (&Applier{DB: d.DB, AgentLog: d.al, Home: home, Now: func() time.Time { return applyNow }}).acceptErr(chat.ID, ""))
	after := coach01State(t, d, home)
	assert.NotEqual(t, before["chat"], after["chat"], "Accept applies the edit")
	for _, k := range []string{"session", "procedure", "additions", "settings.json", "CLAUDE.md"} {
		assert.Equal(t, before[k], after[k], "accepting one proposal leaves %s alone", k)
	}
}

// COACH-01: the destination set is the owner's own setup; a destination that
// names a repository file is not one, and the two files the coach writes live
// under the home folder's .claude directory.
func TestCOACH01_DestinationsAreNeverRepoFiles(t *testing.T) {
	want := []string{DestClaudeMDUser, DestChat, DestProcedure, DestPromptAdd, DestSession, DestSettingsAllow}
	var got []string
	for dest := range textDestinations {
		got = append(got, dest)
	}
	sort.Strings(got)
	sort.Strings(want)
	assert.Equal(t, want, got, "adding a destination is an owner decision: update COACH-01")

	home := filepath.FromSlash("/home/owner")
	for _, path := range []string{claudeSettingsPath(home), claudeMDPath(home)} {
		assert.True(t, strings.HasPrefix(path, filepath.Join(home, ".claude")+string(filepath.Separator)), path)
	}

	// A model that names a repository file as the destination is dropped.
	for _, dest := range []string{"repo_claude_md", "CLAUDE.md", ".watchtower/workflow.md", ".claude/skills/x/SKILL.md"} {
		raw := `{"proposals":[{"title":"t","why":"w","destination":"` + dest + `","workbench_id":0,"prompt_id":"",` +
			`"kind":"add","find":"","replace":"Keep it short.","metric":"corrections","evidence":["s1","s2","s3"]}]}`
		got, err := Validate(raw, proposeInputs())
		require.NoError(t, err)
		assert.Empty(t, got, dest)
	}
}

// COACH-01: the destinations a tuning chat may name are the six weekly ones
// plus five in the owner's home folders (the Claude and Codex user skills, the
// Watchtower pack overlay, ~/.codex/AGENTS.md and the Codex rules). All five
// are global: none is a per-workbench or repository text. The paths they
// resolve to are pinned by the destination tasks.
func TestCOACH01_HomeDestinationsStayUnderHome(t *testing.T) {
	home := []string{DestClaudeSkillUser, DestCodexSkillUser, DestPackOverlay, DestCodexAgentsMDUser, DestCodexRulesAllow}
	want := append([]string{DestClaudeMDUser, DestChat, DestProcedure, DestPromptAdd, DestSession, DestSettingsAllow}, home...)
	var got []string
	for dest := range chatDestinations {
		got = append(got, dest)
	}
	sort.Strings(got)
	sort.Strings(want)
	assert.Equal(t, want, got, "adding a destination is an owner decision: update COACH-01")

	for _, dest := range home {
		assert.True(t, globalDestinations[dest], dest)
		assert.False(t, textDestinations[dest], "%s is not a weekly destination", dest)
		assert.False(t, strings.HasPrefix(dest, "repo_"), dest)
	}

	// The file destinations resolve under <Home>/.claude/, <Home>/.agents/ or
	// <CodexHome>/, with and without an own CODEX_HOME.
	hdir := t.TempDir()
	under := func(path string, roots ...string) bool {
		for _, r := range roots {
			if strings.HasPrefix(path, r+string(filepath.Separator)) {
				return true
			}
		}
		return false
	}
	for _, e := range []Env{{Home: hdir}, {Home: hdir, CodexHome: t.TempDir()}} {
		roots := []string{filepath.Join(hdir, ".claude"), filepath.Join(hdir, ".agents"), e.codexHome()}
		assert.True(t, under(ClaudeSkillPath(e, "x"), filepath.Join(hdir, ".claude")))
		assert.True(t, under(codexAgentsMDPath(e), e.codexHome()))
		assert.True(t, under(codexRulesPath(e), e.codexHome()))
		_, ok := CodexSkillPath(e, "x")
		assert.False(t, ok)
		for _, p := range []string{filepath.Join(e.codexHome(), "skills", "x", "SKILL.md"),
			filepath.Join(hdir, ".agents", "skills", "x", "SKILL.md")} {
			require.NoError(t, os.MkdirAll(filepath.Dir(p), 0o700))
			require.NoError(t, os.WriteFile(p, []byte("x"), 0o600))
			got, ok := CodexSkillPath(e, "x")
			require.True(t, ok)
			assert.True(t, under(got, roots...), got)
			require.NoError(t, os.Remove(p))
		}
		require.NoError(t, os.RemoveAll(filepath.Join(hdir, ".agents")))
	}
	// With a symlinked ~/.claude (dotfiles) the written file is under the
	// folder it resolves to, never anywhere else.
	dot := t.TempDir()
	linked := t.TempDir()
	require.NoError(t, os.Symlink(dot, filepath.Join(linked, ".claude")))
	u, err := userFileOf(Env{Home: linked}, DestClaudeSkillUser, "x")
	require.NoError(t, err)
	resolved, err := filepath.EvalSymlinks(dot)
	require.NoError(t, err)
	assert.True(t, under(u.path, resolved), u.path)

	// A skill name never leaves its skills folder.
	for _, dest := range []string{DestClaudeSkillUser, DestCodexSkillUser} {
		_, err := userFileOf(Env{Home: hdir}, dest, "../../x")
		require.ErrorIs(t, err, errBadSkillName)
	}
}

// COACH-01 (amended, owner ask #1165): a repository file is a destination only
// as one of the five of spec §4.3a, only inside the workbench's own folder,
// never through a symlinked folder, and never from the weekly pass.
func TestCOACH01_RepoFilesOnlyInTheWorkbenchFolder(t *testing.T) {
	want := map[string]string{
		DestRepoClaudeMD:    "CLAUDE.md",
		DestRepoAgentsMD:    "AGENTS.md",
		DestRepoClaudeSkill: ".claude/skills/a/SKILL.md",
		DestRepoCodexSkill:  ".agents/skills/a/SKILL.md",
		DestRepoWorkflow:    ".watchtower/workflow.md",
	}
	got := map[string]bool{}
	for dest := range repoDestinations {
		got[dest] = true
		assert.False(t, textDestinations[dest], "%s is never a weekly destination", dest)
		assert.False(t, globalDestinations[dest], "%s is per workbench", dest)
		assert.False(t, chatDestinations[dest], "%s is not a home destination", dest)
	}
	require.Len(t, got, len(want), "adding a repository destination is an owner decision: update COACH-01")

	d := openDBs(t)
	a := newApplier(t, d)
	for dest, rel := range want {
		skill := ""
		if skillDestinations[dest] {
			skill = "a"
		}
		r, ok := RepoRelPath(dest, skill)
		require.True(t, ok, dest)
		require.Equal(t, rel, r, dest)

		folder, err := filepath.EvalSymlinks(t.TempDir())
		require.NoError(t, err)
		files := map[string]string{"README.md": "readme\n"}
		for _, other := range want {
			files[other] = "text of " + other + "\n"
		}
		for f, text := range files {
			writeFile(t, filepath.Join(folder, filepath.FromSlash(f)), text)
		}
		wb, err := d.CreateWorkbench("acme-"+dest, folder)
		require.NoError(t, err)

		u, err := repoFileOf(folder, dest, skill)
		require.NoError(t, err, dest)
		assert.Equal(t, filepath.Join(folder, filepath.FromSlash(rel)), u.path, dest)
		assert.Equal(t, folder, u.root, dest)

		// readCurrent and writeDestination touch exactly that file.
		p := db.CoachProposal{Destination: dest, WorkbenchID: wb, Skill: skill}
		cur, err := a.readCurrent(p)
		require.NoError(t, err, dest)
		assert.Equal(t, "text of "+rel+"\n", cur.Text, dest)
		_, err = a.writeDestination(p, cur, cur.Text+"Edited.\n", applyNow)
		require.NoError(t, err, dest)
		files[rel] += "Edited.\n"
		assert.Equal(t, files, folderFiles(t, folder), dest)

		// A symlink on the way or at the file is refused.
		if dir := filepath.Dir(filepath.FromSlash(rel)); dir != "." {
			top := filepath.Join(folder, strings.Split(dir, string(filepath.Separator))[0])
			moved := filepath.Join(t.TempDir(), "moved")
			require.NoError(t, os.Rename(top, moved))
			require.NoError(t, os.Symlink(moved, top))
		} else {
			moved := filepath.Join(t.TempDir(), "moved.md")
			require.NoError(t, os.Rename(u.path, moved))
			require.NoError(t, os.Symlink(moved, u.path))
		}
		_, err = a.readCurrent(p)
		require.ErrorIs(t, err, errUnsafeFile, dest)
		_, err = a.writeDestination(p, cur, cur.Text+"Edited.\n", applyNow)
		require.ErrorIs(t, err, errUnsafeFile, dest)
	}

	// A skill name never leaves its skills folder.
	for _, dest := range []string{DestRepoClaudeSkill, DestRepoCodexSkill} {
		for _, bad := range []string{"../x", "..", "a/b", "/x"} {
			_, err := repoFileOf(t.TempDir(), dest, bad)
			require.ErrorIs(t, err, errBadSkillName, bad)
		}
	}

	// The weekly pass drops a model reply naming any of the five, even with
	// the text in its inputs.
	in := proposeInputs()
	for dest := range want {
		in.Texts = append(in.Texts, CurrentText{Destination: dest, WorkbenchID: 1, Text: "Run tests.", Budget: 1000})
	}
	for dest := range want {
		raw := `{"proposals":[{"title":"t","why":"w","destination":"` + dest + `","workbench_id":1,"prompt_id":"",` +
			`"kind":"add","find":"","replace":"Keep it short.","metric":"corrections","evidence":["s1","s2","s3"]}]}`
		got, err := Validate(raw, in)
		require.NoError(t, err)
		assert.Empty(t, got, dest)
	}
}

// folderFiles is every regular file below folder (relative, slash-separated)
// with its text.
func folderFiles(t *testing.T, folder string) map[string]string {
	t.Helper()
	out := map[string]string{}
	require.NoError(t, filepath.WalkDir(folder, func(path string, e fs.DirEntry, err error) error {
		if err != nil || e.IsDir() {
			return err
		}
		rel, err := filepath.Rel(folder, path)
		if err != nil {
			return err
		}
		raw, err := os.ReadFile(path) //nolint:gosec // a test's own temp folder
		out[filepath.ToSlash(rel)] = string(raw)
		return err
	}))
	return out
}

// COACH-01 (amended, owner ask #1165): Watchtower never runs a git write for
// the coach. (a) internal/coach imports no workbenchgit and starts no process:
// the git state reaches Accept and ValidateChatProposal only through the
// RepoState/RepoBranch seams, which have no default there. (b) The tuning
// paths that fill them — the coach and tuning CLI code, which lives only in
// cmd/coach*.go and cmd/tuning*.go, and internal/tuning — call no workbenchgit
// helper but PathStatus, ReadStatus and FileAtHead. (c) Those helpers run git
// only with the read-only verbs status, rev-parse and show (pinned argv by
// argv in workbenchgit's recording-runner tests: TestPathStatus_RunsOnlyStatus,
// TestReadStatus_RunsOnlyReadVerbs). Extend the lists with each new read-only
// helper or caller (the daemon's commit check, Task 2.14); never relax them.
func TestCOACH01_NoGitWrites(t *testing.T) {
	// (a)
	for _, f := range parseDir(t, ".") {
		for _, imp := range f.file.Imports {
			path := strings.Trim(imp.Path.Value, `"`)
			assert.NotEqual(t, "watchtower/internal/workbenchgit", path, f.name)
			assert.NotEqual(t, "os/exec", path, f.name)
		}
		for sel := range selectors(f.file, importNames(f.file, map[string]string{"os": "os", "syscall": "syscall"})) {
			assert.NotContains(t, []string{"os.StartProcess", "syscall.Exec", "syscall.ForkExec", "syscall.StartProcess"},
				sel, f.name)
		}
	}

	// (b)
	tuningPath := func(name string) bool {
		base := filepath.Base(name)
		return strings.HasPrefix(base, "coach") || strings.HasPrefix(base, "tuning")
	}
	allowed := map[string]bool{
		"workbenchgit.PathStatus": true, "workbenchgit.ReadStatus": true, "workbenchgit.FileAtHead": true,
		// Types, not helpers: they run nothing.
		"workbenchgit.Options": true, "workbenchgit.Status": true, "workbenchgit.PathState": true,
		"workbenchgit.StatusFields": true,
	}
	seams := []string{"coach.Applier", "coach.Env", "coach.RepoFileState", "tuning.Deps"}
	pkgs := map[string]string{"watchtower/internal/workbenchgit": "workbenchgit",
		"watchtower/internal/coach": "coach", "watchtower/internal/tuning": "tuning"}
	scanned := 0
	files := parseDir(t, filepath.Join("..", "..", "cmd"))
	if _, err := os.Stat(filepath.Join("..", "tuning")); err == nil {
		files = append(files, parseDir(t, filepath.Join("..", "tuning"))...)
	}
	for _, f := range files {
		inTuning := tuningPath(f.name) || strings.Contains(filepath.ToSlash(f.name), "internal/tuning/")
		for sel := range selectors(f.file, importNames(f.file, pkgs)) {
			if !inTuning {
				assert.NotContains(t, seams, sel, "%s: coach and tuning wiring lives in cmd/coach*.go or cmd/tuning*.go", f.name)
				continue
			}
			if strings.HasPrefix(sel, "workbenchgit.") {
				scanned++
				assert.True(t, allowed[sel], "%s calls %s: only the read-only helpers", f.name, sel)
			}
		}
	}
	assert.Positive(t, scanned, "the scan finds the coach's git reads (coachRepoState, coachRepoBranch)")

	// (c)
	helpers := map[string]bool{"PathStatus": true, "ReadStatus": true, "readStatus": true, "FileAtHead": true,
		"probe": true, "open": true, "locatePaths": true}
	readVerbs := map[string]bool{"status": true, "rev-parse": true, "show": true}
	decls := map[string]*ast.FuncDecl{}
	for _, f := range parseDir(t, filepath.Join("..", "workbenchgit")) {
		for _, d := range f.file.Decls {
			if fd, ok := d.(*ast.FuncDecl); ok {
				decls[fd.Name.Name] = fd
			}
		}
	}
	// runsGit is every function of the package that reaches a git call
	// (.git/.run), at any depth: a fixpoint over the call graph by name.
	callees := map[string][]string{}
	for name, fd := range decls {
		ast.Inspect(fd, func(n ast.Node) bool {
			if c, ok := n.(*ast.CallExpr); ok {
				switch fn := c.Fun.(type) {
				case *ast.Ident:
					callees[name] = append(callees[name], fn.Name)
				case *ast.SelectorExpr:
					callees[name] = append(callees[name], fn.Sel.Name)
				}
			}
			return true
		})
	}
	reaches := map[string]bool{"git": true, "run": true}
	for changed := true; changed; {
		changed = false
		for name, cs := range callees {
			for _, c := range cs {
				if reaches[c] && !reaches[name] {
					reaches[name], changed = true, true
				}
			}
		}
	}
	runsGit := func(name string) bool { return reaches[name] }
	verbs := 0
	for name := range helpers {
		fd, ok := decls[name]
		if !ok {
			continue // FileAtHead lands with Task 2.14
		}
		ast.Inspect(fd.Body, func(n ast.Node) bool {
			c, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			var callee string
			switch fn := c.Fun.(type) {
			case *ast.Ident:
				callee = fn.Name
			case *ast.SelectorExpr:
				callee = fn.Sel.Name
			}
			if callee == "git" || callee == "run" {
				require.GreaterOrEqual(t, len(c.Args), 2, "%s: git call without a verb", name)
				lit, ok := c.Args[1].(*ast.BasicLit)
				require.True(t, ok && lit.Kind == token.STRING, "%s: the git verb must be a literal", name)
				verb := strings.Trim(lit.Value, `"`)
				assert.True(t, readVerbs[verb], "%s runs git %s", name, verb)
				verbs++
				return true
			}
			if _, ok := decls[callee]; ok && !helpers[callee] && runsGit(callee) {
				t.Errorf("%s calls %s, which runs git: add it to the scan only if it is read-only", name, callee)
			}
			return true
		})
	}
	assert.Positive(t, verbs, "the scan finds the helpers' git calls")
}

type parsedFile struct {
	name string
	file *ast.File
}

// parseDir parses the non-test Go files of dir.
func parseDir(t *testing.T, dir string) []parsedFile {
	t.Helper()
	names, err := filepath.Glob(filepath.Join(dir, "*.go"))
	require.NoError(t, err)
	var out []parsedFile
	fset := token.NewFileSet()
	for _, name := range names {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, name, nil, parser.SkipObjectResolution)
		require.NoError(t, err)
		out = append(out, parsedFile{name: name, file: f})
	}
	require.NotEmpty(t, out, dir)
	return out
}

// importNames maps the local name of each import of f in pkgs (import path →
// canonical name) to that canonical name.
func importNames(f *ast.File, pkgs map[string]string) map[string]string {
	out := map[string]string{}
	for _, imp := range f.Imports {
		canonical, ok := pkgs[strings.Trim(imp.Path.Value, `"`)]
		if !ok {
			continue
		}
		local := canonical
		if imp.Name != nil {
			local = imp.Name.Name
		}
		out[local] = canonical
	}
	return out
}

// selectors is the set of "pkg.Name" selectors in f whose pkg is a local
// import name in names, spelled with its canonical name.
func selectors(f *ast.File, names map[string]string) map[string]bool {
	out := map[string]bool{}
	ast.Inspect(f, func(n ast.Node) bool {
		if s, ok := n.(*ast.SelectorExpr); ok {
			if id, ok := s.X.(*ast.Ident); ok {
				if canonical, ok := names[id.Name]; ok {
					out[canonical+"."+s.Sel.Name] = true
				}
			}
		}
		return true
	})
	return out
}
