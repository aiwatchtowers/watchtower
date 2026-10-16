package automations_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/dop251/goja"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/claude"
	"watchtower/internal/db"
)

const shellWorkbenchID = 7

// shellCase is one shell() run on a workbench automation (personal: a
// personal one).
type shellCase struct {
	perms    []string
	personal bool
	dryRun   bool
	shell    automations.ShellRunner // nil = none configured
	wb       automations.WorkbenchResolver
}

// shellFolder is a fresh, symlink-resolved workbench folder.
func shellFolder(t *testing.T) string {
	t.Helper()
	folder, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return folder
}

// realShell records each command and runs it with the process runner.
func realShell() *automationstest.FakeShell {
	return &automationstest.FakeShell{Next: automations.NewProcessShellRunner()}
}

func folderWB(folder string) *automationstest.FakeWorkbench {
	return &automationstest.FakeWorkbench{Info: automations.WorkbenchInfo{ID: shellWorkbenchID, Folder: folder, DefaultAgent: "claude"}}
}

func runShell(t *testing.T, script string, c shellCase) sdkRun {
	t.Helper()
	clock := automationstest.NewFakeClock(time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC))
	b := automations.Backends{Generator: &automationstest.FakeGenerator{}, Registry: fakeTools(), Clock: clock}
	if c.shell != nil {
		b.Shell = c.shell
	}
	if c.wb != nil {
		b.Workbench = c.wb
	}
	scope := automations.Scope{Kind: automations.ScopeWorkbench, WorkbenchID: shellWorkbenchID}
	a := &db.Automation{ID: 3, Slug: "acme", Scope: "workbench", ProjectID: shellWorkbenchID}
	if c.personal {
		scope = automations.Scope{Kind: automations.ScopePersonal}
		a = &db.Automation{ID: 3, Slug: "acme", Scope: "personal"}
	}
	m, err := automations.ParseManifest(c.perms, nil, scope)
	if err != nil {
		t.Fatalf("ParseManifest: %v", err)
	}
	env := &automations.Env{
		Ctx:        context.Background(),
		Run:        &db.AutomationRun{ID: 42, AutomationID: 3},
		Automation: a,
		Recipe:     &automations.Recipe{Script: script, ScriptLine: 10, Scope: scope},
		Manifest:   m,
		DryRun:     c.dryRun,
		Journal:    automations.NewMemoryJournal(),
		Meter:      automations.NewMeter(automations.Budget{Tokens: 50000, Minutes: 5}, clock),
		Buffer:     automations.NewCommitBuffer(nil),
	}
	sb, err := automations.NewSandbox(env, automations.DefaultModules(b))
	if err != nil {
		t.Fatalf("NewSandbox: %v", err)
	}
	out, err := sb.Run()
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	return sdkRun{env: env, out: out}
}

func TestAuto13_ShellExactCommandInWorkbenchFolder(t *testing.T) {
	folder := shellFolder(t)
	sh := realShell()
	r := runShell(t, `
		const out = [shell("pwd").stdout];
		for (const c of ["pwd ", " pwd", "pwd && id"]) {
			try { shell(c); out.push("ran") } catch (e) { out.push(e.name + "|" + e.needed) }
		}
		return out`, shellCase{perms: []string{`shell:"pwd"`}, shell: sh, wb: folderWB(folder)})
	want := []any{folder + "\n", `PermissionDenied|shell:"pwd "`, `PermissionDenied|shell:" pwd"`, `PermissionDenied|shell:"pwd && id"`}
	if !reflect.DeepEqual(r.out, want) {
		t.Fatalf("script returned %#v; want %#v", r.out, want)
	}
	calls := sh.Calls()
	if len(calls) != 1 || calls[0].Cmd != "pwd" || calls[0].Dir != folder {
		t.Fatalf("shell calls = %+v; want only pwd in %s", calls, folder)
	}
	steps := r.env.Journal.Steps()
	if got := stepStatuses(steps); !slices.Equal(got, []string{"shell:ok", "shell:denied", "shell:denied", "shell:denied"}) {
		t.Fatalf("steps = %v", got)
	}
	if steps[0].Permission != `shell:"pwd"` {
		t.Fatalf("permission = %q; want the admitting entry", steps[0].Permission)
	}
}

func TestAuto13_ShellRefusedInPersonalRecipe(t *testing.T) {
	text := "---\nname: Personal shell\ntrigger:\n  manual: true\npermissions:\n  - 'shell:\"x\"'\n---\nRuns x.\n\n```js\nshell(\"x\")\n```\n"
	if _, err := automations.ParseRecipe("personal-shell", []byte(text), automations.Scope{Kind: automations.ScopePersonal}); err == nil {
		t.Fatal("a personal recipe holding shell:\"x\" parsed")
	}
	sh := &automationstest.FakeShell{}
	r := runShell(t, `try { shell("x"); return "ran" } catch (e) { return e.name }`,
		shellCase{personal: true, shell: sh, wb: folderWB(shellFolder(t))})
	if r.out != "PermissionDenied" {
		t.Fatalf("script returned %#v; want PermissionDenied", r.out)
	}
	if n := len(sh.Calls()); n != 0 {
		t.Fatalf("shell calls = %d; want 0", n)
	}
}

// The folder does not exist: had it been stat'ed, the call would have
// failed as missing rather than protected.
func TestShell_RefusedInProtectedFolder(t *testing.T) {
	sh := &automationstest.FakeShell{}
	wb := &automationstest.FakeWorkbench{Info: automations.WorkbenchInfo{ID: shellWorkbenchID,
		Folder: filepath.Join(t.TempDir(), "absent"), Protected: true}}
	r := runShell(t, `try { shell("pwd"); return "ran" } catch (e) { return e.name + "|" + e.message }`,
		shellCase{perms: []string{`shell:"pwd"`}, shell: sh, wb: wb})
	if want := "NotAvailable|this workbench is in a protected folder; use session() or move the folder"; r.out != want {
		t.Fatalf("script returned %#v; want %q", r.out, want)
	}
	if n := len(sh.Calls()); n != 0 {
		t.Fatalf("shell calls = %d; want 0", n)
	}
	if n := wb.CallCount(); n != 1 {
		t.Fatalf("resolver calls = %d; want 1", n)
	}
}

// A stored folder whose folder or ANCESTOR was later replaced by a link is
// refused before anything is stat'ed or run: the link could lead into a
// privacy-protected folder.
func TestShell_RefusedWhenTheFolderPathHasALink(t *testing.T) {
	root := shellFolder(t)
	target := shellFolder(t)
	if err := os.MkdirAll(filepath.Join(target, "repo"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(root, "parent")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(root, "folder")); err != nil {
		t.Fatal(err)
	}
	for name, folder := range map[string]string{
		"folder":   filepath.Join(root, "folder"),
		"ancestor": filepath.Join(root, "parent", "repo"),
	} {
		t.Run(name, func(t *testing.T) {
			sh := realShell()
			r := runShell(t, `try { shell("pwd"); return "ran" } catch (e) { return e.name + "|" + e.message }`,
				shellCase{perms: []string{`shell:"pwd"`}, shell: sh, wb: folderWB(folder)})
			if want := "NotAvailable|the workbench folder path contains a symlink; rebind the workbench to its real folder"; r.out != want {
				t.Fatalf("script returned %#v; want %q", r.out, want)
			}
			if n := len(sh.Calls()); n != 0 {
				t.Fatalf("shell calls = %d; want 0 (no process)", n)
			}
		})
	}
}

func TestShell_NotAvailable(t *testing.T) {
	folder := shellFolder(t)
	missing := &automationstest.FakeWorkbench{Info: automations.WorkbenchInfo{ID: shellWorkbenchID, Folder: filepath.Join(folder, "absent")}}
	gone := &automationstest.FakeWorkbench{Err: fmt.Errorf("reading: %w", db.ErrWorkbenchNotFound)}
	for name, tc := range map[string]struct {
		c    shellCase
		want string
	}{
		"folder missing": {shellCase{shell: &automationstest.FakeShell{}, wb: missing}, "the workbench folder is missing"},
		"workbench gone": {shellCase{shell: &automationstest.FakeShell{}, wb: gone}, "the workbench no longer exists"},
		"no runner":      {shellCase{wb: folderWB(folder)}, "no shell runner is configured"},
		"no resolver":    {shellCase{shell: &automationstest.FakeShell{}}, "no workbench resolver is configured"},
	} {
		t.Run(name, func(t *testing.T) {
			tc.c.perms = []string{`shell:"pwd"`}
			r := runShell(t, `try { shell("pwd"); return "ran" } catch (e) { return e.name + "|" + e.message }`, tc.c)
			if want := "NotAvailable|" + tc.want; r.out != want {
				t.Fatalf("script returned %#v; want %q", r.out, want)
			}
			if fs, ok := tc.c.shell.(*automationstest.FakeShell); ok && len(fs.Calls()) != 0 {
				t.Fatalf("shell calls = %d; want 0", len(fs.Calls()))
			}
		})
	}
}

func TestShell_ValidationError(t *testing.T) {
	sh := &automationstest.FakeShell{}
	r := runShell(t, `const out = [];
		for (const c of [undefined, "", 3]) { try { shell(c); out.push("ran") } catch (e) { out.push(e.name) } }
		return out`, shellCase{perms: []string{`shell:"pwd"`}, shell: sh, wb: folderWB(shellFolder(t))})
	if want := []any{"ValidationError", "ValidationError", "ValidationError"}; !reflect.DeepEqual(r.out, want) {
		t.Fatalf("script returned %#v; want %#v", r.out, want)
	}
	if n := len(sh.Calls()); n != 0 {
		t.Fatalf("shell calls = %d; want 0", n)
	}
}

// shellAddedByShell is what /bin/sh itself puts in a child's environment.
var shellAddedByShell = []string{"PWD", "SHLVL", "_", "OLDPWD"}

func TestShell_EnvHasRunMarkerAndNoSecrets(t *testing.T) {
	t.Setenv("SLACK_TOKEN", "x")
	t.Setenv("WATCHTOWER_TERMINAL_SESSION_ID", "5")
	t.Setenv("CLAUDECODE", "1")
	t.Setenv("HOME", t.TempDir())
	t.Setenv("LANG", "en_US.UTF-8")
	t.Setenv("USER", "acme")
	folder := shellFolder(t)
	sh := realShell()
	r := runShell(t, `return shell("env").stdout`, shellCase{perms: []string{`shell:"env"`}, shell: sh, wb: folderWB(folder)})
	want := []string{"PATH=" + claude.RichPATH(), "HOME=" + os.Getenv("HOME"), "LANG=en_US.UTF-8", "USER=acme",
		"WATCHTOWER_AUTOMATION_RUN_ID=42"}
	if calls := sh.Calls(); len(calls) != 1 || !slices.Equal(calls[0].Env, want) {
		t.Fatalf("command env = %+v; want %q", calls, want)
	}
	// The rich PATH, not launchd's minimal one: Homebrew's gh and make resolve.
	if !slices.Contains(filepath.SplitList(claude.RichPATH()), "/opt/homebrew/bin") {
		t.Fatalf("PATH %q lacks /opt/homebrew/bin", claude.RichPATH())
	}
	got := envLines(t, r.out)
	for _, kv := range want {
		k, v, _ := strings.Cut(kv, "=")
		if got[k] != v {
			t.Fatalf("child %s = %q; want %q (env %v)", k, got[k], v, got)
		}
	}
	for k := range got {
		if !slices.Contains(shellAddedByShell, k) && !slices.ContainsFunc(want, func(kv string) bool { return strings.HasPrefix(kv, k+"=") }) {
			t.Fatalf("child env has %s; want only %q plus %q", k, want, shellAddedByShell)
		}
	}

	// An unset variable is left out, never passed empty.
	if err := os.Unsetenv("LANG"); err != nil {
		t.Fatal(err)
	}
	sh = realShell()
	r = runShell(t, `return shell("env").stdout`, shellCase{perms: []string{`shell:"env"`}, shell: sh, wb: folderWB(folder)})
	if _, has := envLines(t, r.out)["LANG"]; has || slices.ContainsFunc(sh.Calls()[0].Env, func(kv string) bool { return strings.HasPrefix(kv, "LANG=") }) {
		t.Fatalf("an unset LANG reached the child: %v", sh.Calls()[0].Env)
	}
}

func envLines(t *testing.T, out any) map[string]string {
	t.Helper()
	s, ok := out.(string)
	if !ok {
		t.Fatalf("env output = %#v", out)
	}
	m := map[string]string{}
	for _, line := range strings.Split(strings.TrimSuffix(s, "\n"), "\n") {
		k, v, _ := strings.Cut(line, "=")
		m[k] = v
	}
	return m
}

func TestShell_NonZeroExitIsAResult(t *testing.T) {
	r := runShell(t, `const r = shell("exit 3"); return r.exit_code + "|" + r.stdout + "|" + (r.truncated === undefined)`,
		shellCase{perms: []string{`shell:"exit 3"`}, shell: realShell(), wb: folderWB(shellFolder(t))})
	if r.out != "3||true" {
		t.Fatalf("script returned %#v; want 3||true", r.out)
	}
	if steps := r.env.Journal.Steps(); len(steps) != 1 || steps[0].Status != automations.StepOK || steps[0].ResultSummary != `{"exit_code":3}` {
		t.Fatalf("steps = %+v; want one ok step summarising the exit code", steps)
	}
}

func TestShell_DryRunStartsNoProcess(t *testing.T) {
	sh := &automationstest.FakeShell{}
	r := runShell(t, `return shell("make release").status`,
		shellCase{perms: []string{`shell:"make release"`}, dryRun: true, shell: sh, wb: folderWB(shellFolder(t))})
	if r.out != automations.StepDryRun {
		t.Fatalf("script returned %#v; want dry_run", r.out)
	}
	if n := len(sh.Calls()); n != 0 {
		t.Fatalf("shell calls = %d; want 0", n)
	}
	if got := stepStatuses(r.env.Journal.Steps()); !slices.Equal(got, []string{"shell:dry_run"}) {
		t.Fatalf("steps = %v", got)
	}
}

func TestShell_OutputTailCappedAt256KiB(t *testing.T) {
	const cmd = `head -c 307200 /dev/zero | tr '\000' x; printf END; printf err >&2`
	folder := shellFolder(t)
	res, err := automations.NewProcessShellRunner().Run(context.Background(),
		automations.ShellCommand{Cmd: cmd, Dir: folder, Env: []string{"PATH=" + os.Getenv("PATH")}})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Stdout) != automations.MaxShellStreamBytes || !strings.HasSuffix(res.Stdout, "xEND") || !res.StdoutTruncated {
		t.Fatalf("stdout = %d bytes (truncated %v); want the last %d", len(res.Stdout), res.StdoutTruncated, automations.MaxShellStreamBytes)
	}
	if res.Stderr != "err" || res.StderrTruncated {
		t.Fatalf("stderr = %q (truncated %v); want err, whole", res.Stderr, res.StderrTruncated)
	}
	r := runShell(t, fmt.Sprintf(`const r = shell(%q); return r.truncated + "|" + r.stdout.endsWith("xEND") + "|" + r.stderr`, cmd),
		shellCase{perms: []string{`shell:` + strconv.Quote(cmd)}, shell: realShell(), wb: folderWB(folder)})
	if r.out != "true|true|err" {
		t.Fatalf("script returned %#v", r.out)
	}
}

func TestShell_OversizedOutputTruncatedNeverFails(t *testing.T) {
	lines := func(prefix string) string {
		return `awk 'BEGIN{for(i=0;i<30000;i++)print "` + prefix + ` " i}'`
	}
	for _, tc := range []struct {
		name, cmd string
		exit      float64
		check     func(t *testing.T, out map[string]any, raw []byte)
		cut       []string
	}{
		{name: "both streams", cmd: lines("line") + "; " + lines("err") + " >&2; exit 4", exit: 4, cut: []string{"stdout", "stderr"},
			check: func(t *testing.T, out map[string]any, _ []byte) {
				so, se := out["stdout"].(string), out["stderr"].(string)
				if !strings.HasSuffix(so, "\nline 29999\n") || !strings.HasSuffix(se, "\nerr 29999\n") {
					t.Fatalf("streams are not tails: stdout …%q, stderr …%q", so[len(so)-20:], se[len(se)-20:])
				}
				if len(so) < 110<<10 || len(se) < 110<<10 { // each newline escapes to two bytes
					t.Fatalf("stdout %d / stderr %d bytes; want each about half the room", len(so), len(se))
				}
			}},
		{name: "short stderr kept whole", cmd: `head -c 10240 /dev/zero | tr '\000' e >&2; head -c 409600 /dev/zero | tr '\000' o`, cut: []string{"stdout"},
			check: func(t *testing.T, out map[string]any, raw []byte) {
				if se := out["stderr"].(string); len(se) != 10240 {
					t.Fatalf("stderr = %d bytes; want 10240, whole", len(se))
				}
				if len(raw) < automations.MaxSDKResultBytes-64 {
					t.Fatalf("result = %d bytes; want stdout to fill the remaining room", len(raw))
				}
			}},
		{name: "control characters", cmd: `head -c 200000 /dev/zero | tr '\000' '\001'`, cut: []string{"stdout"},
			check: func(t *testing.T, out map[string]any, raw []byte) {
				if so := out["stdout"].(string); len(so) < 40000 || strings.Trim(so, "\x01") != "" {
					t.Fatalf("stdout = %d bytes; want a tail of control characters filling the room", len(so))
				}
			}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := runShell(t, fmt.Sprintf(`return shell(%q)`, tc.cmd),
				shellCase{perms: []string{`shell:` + strconv.Quote(tc.cmd)}, shell: realShell(), wb: folderWB(shellFolder(t))})
			out, ok := r.out.(map[string]any)
			if !ok {
				t.Fatalf("script returned %#v", r.out)
			}
			raw, err := json.Marshal(out)
			if err != nil {
				t.Fatal(err)
			}
			if len(raw) > automations.MaxSDKResultBytes {
				t.Fatalf("result = %d bytes; want ≤ %d", len(raw), automations.MaxSDKResultBytes)
			}
			if out["exit_code"] != tc.exit || out["truncated"] != true {
				t.Fatalf("exit_code %v truncated %v; want %v, true", out["exit_code"], out["truncated"], tc.exit)
			}
			tc.check(t, out, raw)
			steps := r.env.Journal.Steps()
			want := fmt.Sprintf(`{"exit_code":%v,"truncated":%s}`, tc.exit, mustJSON(t, tc.cut))
			if len(steps) != 1 || steps[0].Status != automations.StepOK || steps[0].ResultSummary != want {
				t.Fatalf("steps = %+v; want one ok step summarised %s", steps, want)
			}
		})
	}
}

func mustJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// shellRecipe is a manual workbench recipe allowed one shell command; CMD,
// EXTRA (more frontmatter lines) and SCRIPT are replaced.
const shellRecipe = "---\nname: Shell test\ntrigger:\n  manual: true\npermissions:\n  - 'shell:\"CMD\"'\nEXTRA---\n" +
	"Runs one shell command.\n\n```js\nSCRIPT\n```\n"

// newShellExFixture is an executor fixture whose backends run shell() for
// real in a workbench bound to a temp folder.
func newShellExFixture(t *testing.T, modules func(f *exFixture) []automations.Module) (*exFixture, *automationstest.FakeShell, int64, string) {
	t.Helper()
	sh := realShell()
	f := newExFixture(t, exOpts{modules: modules, backends: func(f *exFixture, b *automations.Backends) {
		b.Shell = sh
		b.Workbench = automations.NewWorkbenchResolver(f.d, func() string { return "claude" }, func(string) bool { return false })
	}})
	wb, folder := newWorkbench(t, f.d)
	return f, sh, wb, folder
}

// startShellRun seeds a confirmed, enabled recipe running cmd, starts its
// run and returns its id. A cleanup cancels the run and waits for it.
func startShellRun(t *testing.T, f *exFixture, wb int64, folder, cmd, script, extra string) int64 {
	t.Helper()
	writeWorkbenchRecipe(t, folder, "shell", strings.NewReplacer("CMD", cmd, "EXTRA", extra, "SCRIPT", script).Replace(shellRecipe))
	rescanWorkbench(t, f.ix, wb, folder)
	a := workbenchRow(t, f.d, wb, "shell")
	if a.ParseError != "" {
		t.Fatalf("the recipe does not parse: %s", a.ParseError)
	}
	if err := f.d.ConfirmAutomation(a.ID, a.ApprovalHash, exStart); err != nil {
		t.Fatal(err)
	}
	if err := f.d.SetAutomationEnabled(a.ID, true, exStart); err != nil {
		t.Fatal(err)
	}
	id := f.enqueue(t, a, db.TriggerManual)
	t.Cleanup(func() {
		_, _ = f.d.CancelAutomationRun(id, f.clock.Now())
		f.e.Wake()
		f.e.Wait()
	})
	f.stepNoWait(t, 1)
	return id
}

// pgidFile is where the long-running test commands write their shell's pid,
// which Setpgid makes the group id.
const pgidFile = "shell.pgid"

// waitPgid waits for the command's group id; a cleanup kills the group.
func waitPgid(t *testing.T, folder string) int {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		b, err := os.ReadFile(filepath.Join(folder, pgidFile))
		if err == nil && strings.HasSuffix(string(b), "\n") {
			pgid, err := strconv.Atoi(strings.TrimSpace(string(b)))
			if err != nil || pgid <= 1 {
				t.Fatalf("pgid file = %q", b)
			}
			t.Cleanup(func() { _ = syscall.Kill(-pgid, syscall.SIGKILL) })
			return pgid
		}
		if time.Now().After(deadline) {
			t.Fatal("the command never wrote its pgid")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// waitGroupGone fails unless every process of group pgid is gone within d.
func waitGroupGone(t *testing.T, pgid int, d time.Duration) {
	t.Helper()
	deadline := time.Now().Add(d)
	for {
		err := syscall.Kill(-pgid, 0)
		if errors.Is(err, syscall.ESRCH) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("process group %d still alive after %s (kill 0 = %v)", pgid, d, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestShell_KillsProcessGroupOnInterrupt(t *testing.T) {
	const cmd = `echo $$ > shell.pgid; sleep 30 & sleep 30; wait`
	f, _, wb, folder := newShellExFixture(t, nil)
	id := startShellRun(t, f, wb, folder, cmd, fmt.Sprintf("shell(%q)", cmd), "")
	pgid := waitPgid(t, folder)
	if ok, err := f.d.CancelAutomationRun(id, f.clock.Now()); err != nil || !ok {
		t.Fatalf("cancel = (%v, %v)", ok, err)
	}
	f.e.Wake()
	waitGroupGone(t, pgid, 2*time.Second)
	f.e.Wait()
	f.wantRun(t, id, db.RunCancelled, db.ErrKindCancelled)
}

// spendModule's spend() spends 59 s of active time on the fake clock (the
// pause/resume rearms the run's deadline watcher).
func spendModule(f *exFixture) []automations.Module {
	return []automations.Module{exModule{name: "spend", fns: map[string]automations.SDKFunc{
		"spend": func(env *automations.Env, _ goja.FunctionCall, _ *goja.Runtime) (any, error) {
			f.clock.Advance(59 * time.Second)
			env.Meter.PauseActive()
			env.Meter.ResumeActive()
			return nil, nil
		},
	}}}
}

func TestShell_TimeoutIsRemainingActiveBudget(t *testing.T) {
	const cmd = `echo $$ > shell.pgid; sleep 5`
	f, sh, wb, folder := newShellExFixture(t, spendModule)
	start := time.Now()
	id := startShellRun(t, f, wb, folder, cmd, fmt.Sprintf("spend(); shell(%q)", cmd), "budget: {minutes: 1}\n")
	pgid := waitPgid(t, folder)
	f.e.Wait()
	if took := time.Since(start); took > 4*time.Second {
		t.Fatalf("the run took %s; want the command killed after about 1 s", took)
	}
	f.wantRun(t, id, db.RunTimedOut, db.ErrKindTimeout)
	waitGroupGone(t, pgid, 2*time.Second)
	calls := sh.Calls()
	if len(calls) != 1 {
		t.Fatalf("shell calls = %d; want 1", len(calls))
	}
	if left := calls[0].Deadline.Sub(start); left < 900*time.Millisecond || left > 1500*time.Millisecond {
		t.Fatalf("command deadline = start + %s; want about 1 s (the remaining active budget)", left)
	}
}
