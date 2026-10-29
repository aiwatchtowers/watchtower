package llmusage

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// knownNonLLMExec is every function that starts a process and is not an LLM
// call (key pkg.Func or pkg.(*Type).Method → why). A process start anywhere
// else must record into llmusage in the same function (directly, or through
// a same-package record* helper that does). A function that runs claude or
// codex for a model answer never belongs here: it records.
var knownNonLLMExec = map[string]string{
	"agentlog.WorktreeRoots":             "git worktree list",
	"auth.IsCertTrusted":                 "security verify-cert on the local TLS certificate",
	"auth.OpenBrowser":                   "opens the OAuth URL in the browser (open / xdg-open)",
	"auth.TrustCert":                     "security import / add-trusted-cert of the local TLS certificate",
	"automations.processShellRunner.Run": "an owner automation's shell() command, not a model call",
	"chat.(*claudeBackend).spawnLocked":  "the warm claude chat child; each turn is recorded from its result line by ClaudeTranslator (recordTurn/usageCall)",
	"chat.NewChildSandboxAt":             "probes sandbox-exec with /usr/bin/true",
	"claude.loginShellPATH":              "login shell `echo $PATH`",
	"claude.loginShellWhich":             "login shell `which claude`",
	"claude.readLoginShellEnv":           "login shell `env -0`",
	"claudesession.SystemProcs.Start":    "ps -o lstart",
	"cmd.LaunchSpecReview":               "starts this binary's `workbench spec-review run`, whose reviewer call records in that process",
	"cmd.execCommandRunner":              "claude mcp add/remove/get for the workbench install (MCP config, no model call)",
	"cmd.registerMCPWithClaudeCode":      "claude mcp add (MCP config, no model call)",
	"cmd.runIntegrateRemove":             "claude mcp remove (MCP config, no model call)",
	"cmd.runQuickSync":                   "runs this binary's `sync`, which records its own calls",
	"cmd.runSyncDetach":                  "re-execs this binary as the detached daemon, which records its own calls",
	"codewalk.gitCheckIgnore":            "git check-ignore",
	"codewalk.gitListFiles":              "git ls-files",
	"codex.codexVersion":                 "codex --version probe",
	"codex.loginShellPATH":               "login shell `echo $PATH`",
	"codex.loginShellWhich":              "login shell `which codex`",
	"codex.startAppServerProcess":        "codex app-server for hook trust, no model call",
	"daemon.runPSLocaleIndependent":      "ps -p",
	"externalmcp.discoveryTransport":     "starts an owner Quick Connection's MCP server to list its tools",
	"extract.(*Extractor).runPDFHelper":  "our own PDF helper executable",
	"extract.(*helperOCR).run":           "the Vision OCR helper",
	"extract.runCodesign":                "codesign --verify of the OCR helper",
	"gitbin.run":                         "git",
	"media.runSips":                      "sips image conversion",
	"oauthpage.openURL":                  "/usr/bin/open of an OAuth page",
	"ownerconfirm.codesign":              "codesign of the Desktop app",
	"planusage.DefaultCredentialSource":  "security find-generic-password (the Claude Code token)",
	"sessioncleanup.runCommand":          "ps / lsof",
	"sessionhost.startSession":           "the owner's interactive PTY, measured by agentlog",
}

// knownNonLLMHTTP is every function that sends an HTTP request in a package
// that talks to an LLM endpoint and is not itself a model call.
var knownNonLLMHTTP = map[string]string{
	"ollama.ListModels": "model list, no generation",
}

// llmEndpoints are the URL path fragments that mark a package as an LLM
// HTTP client. Residual risk: an HTTP leaf in a package with none of these
// literals is not checked (named in the feature note).
var llmEndpoints = []string{"/chat/completions", "/v1/messages", "/api/chat", "/api/generate", "/responses"}

// TestLLMUSAGE01_LeavesRecord fails when a process start or an LLM HTTP call in cmd/
// or internal/ neither records into llmusage in its function nor is listed
// above with a reason.
func TestLLMUSAGE01_LeavesRecord(t *testing.T) {
	root := repoRoot(t)
	for _, list := range []map[string]string{knownNonLLMExec, knownNonLLMHTTP} {
		for k, reason := range list {
			if strings.TrimSpace(reason) == "" {
				t.Errorf("%s is listed without a reason", k)
			}
		}
	}
	res, err := checkLeaves([]string{filepath.Join(root, "cmd"), filepath.Join(root, "internal")}, knownNonLLMExec, knownNonLLMHTTP)
	if err != nil {
		t.Fatal(err)
	}
	for _, l := range res.unrecorded {
		t.Errorf("%s: %s calls %s and does not record into llmusage: record it (llmusage.Record, or a same-package record* helper that does), "+
			"or add %q to %s with the reason it is not an LLM call", l.pos, l.fn, l.call, l.fn, l.list)
	}
	for _, k := range res.stale {
		t.Errorf("%s is listed but starts no process and sends no LLM-package request any more: remove it", k)
	}
}

// TestLLMUsageLeavesCatchesNewLeaf runs the checker over testdata/leaves:
// every unrecorded, unlisted leaf there is reported, the recording and the
// listed functions are not.
func TestLLMUsageLeavesCatchesNewLeaf(t *testing.T) {
	res, err := checkLeaves([]string{filepath.Join("testdata", "leaves")},
		map[string]string{"leaves.listedTool": "git"}, map[string]string{})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, l := range res.unrecorded {
		got = append(got, l.fn+" "+l.call)
	}
	want := []string{
		"leaves.(*Client).fromField exec.CommandContext",
		"leaves.fromLocal exec.Command",
		"leaves.postChat http.NewRequestWithContext",
		"leaves.postChat (*http.Client).Do",
		"leaves.recordsNothing exec.Command",
		"leaves.secondLeaf exec.Command",
	}
	if !slices.Equal(got, want) {
		t.Fatalf("reported:\n  %s\nwant:\n  %s", strings.Join(got, "\n  "), strings.Join(want, "\n  "))
	}
	if len(res.stale) != 0 {
		t.Fatalf("stale = %v; want none", res.stale)
	}
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
			t.Fatal("no go.mod above the test's working directory")
		}
		dir = parent
	}
}

type leaf struct {
	fn, call, pos, list string
}

type leafResult struct {
	unrecorded []leaf
	stale      []string // listed keys with no leaf
}

// checkLeaves parses every non-test .go file under roots (testdata folders
// below a root skipped), one package per directory.
func checkLeaves(roots []string, knownExec, knownHTTP map[string]string) (leafResult, error) {
	dirs := map[string][]string{}
	for _, root := range roots {
		err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				if path != root && d.Name() == "testdata" {
					return filepath.SkipDir
				}
				return nil
			}
			if strings.HasSuffix(path, ".go") && !strings.HasSuffix(path, "_test.go") {
				dirs[filepath.Dir(path)] = append(dirs[filepath.Dir(path)], path)
			}
			return nil
		})
		if err != nil {
			return leafResult{}, err
		}
	}
	var res leafResult
	seen := map[string]bool{}
	fset := token.NewFileSet()
	for _, files := range dirs {
		var parsed []*ast.File
		for _, path := range files {
			f, err := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
			if err != nil {
				return leafResult{}, err
			}
			parsed = append(parsed, f)
		}
		for _, l := range packageLeaves(fset, parsed) {
			list := knownExec
			l.list = "knownNonLLMExec"
			if l.http {
				list, l.list = knownHTTP, "knownNonLLMHTTP"
			}
			seen[l.list+" "+l.fn] = true
			if _, ok := list[l.fn]; ok || l.recorded {
				continue
			}
			res.unrecorded = append(res.unrecorded, l.leaf)
		}
	}
	for name, list := range map[string]map[string]string{"knownNonLLMExec": knownExec, "knownNonLLMHTTP": knownHTTP} {
		for k := range list {
			if !seen[name+" "+k] {
				res.stale = append(res.stale, name+" "+k)
			}
		}
	}
	sort.Slice(res.unrecorded, func(i, j int) bool {
		a, b := res.unrecorded[i], res.unrecorded[j]
		if a.fn != b.fn {
			return a.fn < b.fn
		}
		return a.call > b.call // within a function: exec/http.* before (*http.Client).Do
	})
	sort.Strings(res.stale)
	return res, nil
}

type pkgLeaf struct {
	leaf
	http, recorded bool
}

// importName is the local name of the import path in f ("" = not imported).
func importName(f *ast.File, path string) string {
	for _, imp := range f.Imports {
		p, _ := strconv.Unquote(imp.Path.Value)
		if p != path {
			continue
		}
		if imp.Name != nil {
			return imp.Name.Name
		}
		return p[strings.LastIndex(p, "/")+1:]
	}
	return ""
}

// fnBody is one top-level declaration: a function, or a package-level var
// (its initialiser may hold a func literal).
type fnBody struct {
	key, name string
	node      ast.Node
	f         *ast.File
}

// packageLeaves finds the process starts and LLM-package HTTP calls of one
// package, each marked recorded when its enclosing top-level function
// records (a call inside a func literal belongs to its FuncDecl).
func packageLeaves(fset *token.FileSet, files []*ast.File) []pkgLeaf {
	if len(files) == 0 {
		return nil
	}
	bodies := packageBodies(files)
	records := recordingFuncs(bodies)
	llmPkg := isLLMPackage(files)
	var out []pkgLeaf
	for _, b := range bodies {
		for _, s := range leafSites(b, llmPkg) {
			s.pos = fset.Position(s.at.Pos()).String()
			out = append(out, pkgLeaf{leaf: s.leaf, http: s.http, recorded: records(b.key)})
		}
	}
	return out
}

// isLLMPackage reports whether a string literal of the package names an LLM
// endpoint.
func isLLMPackage(files []*ast.File) bool {
	found := false
	for _, f := range files {
		ast.Inspect(f, func(n ast.Node) bool {
			if lit, ok := n.(*ast.BasicLit); ok && lit.Kind == token.STRING &&
				slices.ContainsFunc(llmEndpoints, func(e string) bool { return strings.Contains(lit.Value, e) }) {
				found = true
			}
			return !found
		})
	}
	return found
}

func packageBodies(files []*ast.File) []fnBody {
	pkg := files[0].Name.Name
	var bodies []fnBody
	for _, f := range files {
		for _, d := range f.Decls {
			switch d := d.(type) {
			case *ast.FuncDecl:
				bodies = append(bodies, fnBody{funcKey(pkg, d), d.Name.Name, d, f})
			case *ast.GenDecl:
				for _, s := range d.Specs {
					if vs, ok := s.(*ast.ValueSpec); ok && len(vs.Names) > 0 {
						bodies = append(bodies, fnBody{pkg + "." + vs.Names[0].Name, vs.Names[0].Name, vs, f})
					}
				}
			}
		}
	}
	return bodies
}

// recordingFuncs returns whether the body with a key records: it calls
// llmusage.Record, or a record* helper that records. A helper records when
// it calls llmusage.Record or another recording record* helper. Helpers are
// matched by bare name (a call's receiver type is not resolved): a record*
// name records when any function or method of that name in the package does.
func recordingFuncs(bodies []fnBody) func(key string) bool {
	direct := map[string]bool{}          // function key → calls llmusage.Record
	recordCalls := map[string][]string{} // function key → record* names it calls
	for _, b := range bodies {
		lu := importName(b.f, "watchtower/internal/llmusage")
		ast.Inspect(b.node, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			name := ""
			switch fn := call.Fun.(type) {
			case *ast.SelectorExpr:
				if id, ok := fn.X.(*ast.Ident); ok && lu != "" && id.Name == lu && fn.Sel.Name == "Record" {
					direct[b.key] = true
				}
				name = fn.Sel.Name
			case *ast.Ident:
				name = fn.Name
			}
			if strings.HasPrefix(name, "record") {
				recordCalls[b.key] = append(recordCalls[b.key], name)
			}
			return true
		})
	}
	recorders := map[string]bool{}
	records := func(key string) bool {
		return direct[key] || slices.ContainsFunc(recordCalls[key], func(c string) bool { return recorders[c] })
	}
	for changed := true; changed; {
		changed = false
		for _, b := range bodies {
			if strings.HasPrefix(b.name, "record") && !recorders[b.name] && records(b.key) {
				recorders[b.name], changed = true, true
			}
		}
	}
	return records
}

type site struct {
	leaf
	at   ast.Node
	http bool
}

// leafSites are b's process starts and, in an LLM package, its HTTP calls.
func leafSites(b fnBody, llmPkg bool) []site {
	execName, osName := importName(b.f, "os/exec"), importName(b.f, "os")
	sysName, ptyName := importName(b.f, "syscall"), importName(b.f, "github.com/creack/pty")
	httpName := ""
	if llmPkg {
		httpName = importName(b.f, "net/http")
	}
	is := func(id *ast.Ident, local string) bool { return local != "" && id.Name == local }
	var out []site
	add := func(n ast.Node, call string, http bool) {
		out = append(out, site{leaf: leaf{fn: b.key, call: call}, at: n, http: http})
	}
	ast.Inspect(b.node, func(n ast.Node) bool {
		switch n := n.(type) {
		case *ast.SelectorExpr:
			id, ok := n.X.(*ast.Ident)
			if !ok {
				return true
			}
			sel := n.Sel.Name
			switch {
			case is(id, execName) && (sel == "Command" || sel == "CommandContext"):
				add(n, "exec."+sel, false)
			case is(id, osName) && sel == "StartProcess",
				is(id, sysName) && (sel == "Exec" || sel == "ForkExec"),
				is(id, ptyName) && strings.HasPrefix(sel, "Start"):
				add(n, id.Name+"."+sel, false)
			case is(id, httpName) && (strings.HasPrefix(sel, "NewRequest") || strings.HasPrefix(sel, "Post") || sel == "Get" || sel == "Head"):
				add(n, "http."+sel, true)
			}
		case *ast.CallExpr:
			if s, ok := n.Fun.(*ast.SelectorExpr); ok && httpName != "" && s.Sel.Name == "Do" {
				add(n, "(*http.Client).Do", true)
			}
		}
		return true
	})
	return out
}

// funcKey is pkg.Func or pkg.(*Type).Method / pkg.Type.Method.
func funcKey(pkg string, d *ast.FuncDecl) string {
	if d.Recv == nil || len(d.Recv.List) == 0 {
		return pkg + "." + d.Name.Name
	}
	t := d.Recv.List[0].Type
	star := false
	if s, ok := t.(*ast.StarExpr); ok {
		t, star = s.X, true
	}
	switch g := t.(type) {
	case *ast.IndexExpr:
		t = g.X
	case *ast.IndexListExpr:
		t = g.X
	}
	name := fmt.Sprint(t)
	if id, ok := t.(*ast.Ident); ok {
		name = id.Name
	}
	if star {
		return fmt.Sprintf("%s.(*%s).%s", pkg, name, d.Name.Name)
	}
	return fmt.Sprintf("%s.%s.%s", pkg, name, d.Name.Name)
}
