package daemon

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

// spawnKind is what a root's process starts must pass on.
type spawnKind int

const (
	// spawnBackground: background work (the daemon's phases, automation
	// runs, the spec-review sweep). The child carries the work's origin:
	// aiconsent.ChildEnv, an originEnv parameter, or automationAgentEnv(ctx, …).
	spawnBackground spawnKind = iota
	// spawnOwner: the hub and the chat engine the daemon hosts, whose spawns
	// serve one owner request (Decision 3 of #1886): aiconsent.OwnerEnv, or
	// aiconsent.ChildEnv for a background unit.
	spawnOwner
)

type spawnRoot struct {
	path string // a folder (walked, testdata skipped) or one file, from the repo root
	kind spawnKind
}

// bgaiSpawnRoots are the code that background work, or the hub and chat
// engine hosted by the background daemon, starts processes from — with the
// launchers they call in cmd.
var bgaiSpawnRoots = []spawnRoot{
	{"internal/daemon", spawnBackground},
	{"internal/automations", spawnBackground},
	{"cmd/workbench_spec_review_launch.go", spawnBackground},
	{"cmd/watchman_backtest.go", spawnBackground},
	{"cmd/automations_backends.go", spawnBackground},
	{"internal/chatengine", spawnOwner},
	{"internal/hub", spawnOwner},
}

// bgaiSpawnExempt is every spawn that needs no origin, keyed by its program
// literal or its function (pkg.Func, pkg.Type.Method, pkg.(*Type).Method) → why.
var bgaiSpawnExempt = map[string]string{
	"ps":                                 "process identity, no model",
	"hub.bridgeLauncher":                 "the CloudKit bridge helper (WatchtowerCloudBridge.app): no model",
	"automations.processShellRunner.Run": "shell() commands: shellEnv sets the run's origin in ShellCommand.Env",
}

// bgaiSpawnUnwalked are packages background work reaches that this checker
// does not walk, each with the reason their children are covered.
var bgaiSpawnUnwalked = map[string]string{
	"internal/sessionstart": "spawns through the session host, no exec: a run's session carries the run's " +
		"origin (Mode.OriginEnv: admitted run:<id> for a background trigger, pinned by " +
		"TestBGAI01_RunSessionsCarryTheirOrigin there); the hub's sessions are the owner's, from the phone",
}

// TestBGAI01_EveryDaemonSpawnSetsOrigin fails when a process start under
// bgaiSpawnRoots does not set its environment from the origin its root
// requires and is not listed in bgaiSpawnExempt with a reason.
func TestBGAI01_EveryDaemonSpawnSetsOrigin(t *testing.T) {
	root := filepath.Join("..", "..")
	for _, list := range []map[string]string{bgaiSpawnExempt, bgaiSpawnUnwalked} {
		for k, reason := range list {
			if strings.TrimSpace(reason) == "" {
				t.Errorf("%s is listed without a reason", k)
			}
		}
	}
	for dir := range bgaiSpawnUnwalked {
		if _, err := os.Stat(filepath.Join(root, dir)); err != nil {
			t.Errorf("%s is listed as unwalked but is gone: remove it", dir)
		}
	}
	roots := make([]spawnRoot, 0, len(bgaiSpawnRoots))
	for _, r := range bgaiSpawnRoots {
		roots = append(roots, spawnRoot{filepath.Join(root, r.path), r.kind})
	}
	res, err := checkSpawns(roots, bgaiSpawnExempt)
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range res.findings {
		t.Errorf("%s: %s starts a process (%s) whose env carries no AI origin: set its Env from %s, "+
			"or add %q (or its program) to bgaiSpawnExempt with the reason it needs none", f.pos, f.fn, f.call, f.want, f.fn)
	}
	for _, k := range res.stale {
		t.Errorf("%s is exempt but matches no spawn any more: remove it", k)
	}
}

// TestBGAI01_SpawnCheckerCatchesNewSpawn runs the checker over testdata: the
// bare spawn and the bad half of mixed in bad are reported, nothing in good
// is.
func TestBGAI01_SpawnCheckerCatchesNewSpawn(t *testing.T) {
	exempt := map[string]string{"ps": "no model"}
	res, err := checkSpawns([]spawnRoot{{filepath.Join("testdata", "spawns", "bad"), spawnBackground}}, exempt)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, f := range res.findings {
		got = append(got, f.fn+" "+f.call)
	}
	want := []string{"spawns.bareSpawn exec.Command", "spawns.mixed os.StartProcess", "spawns.mixed exec.Cmd{}"}
	if !slices.Equal(got, want) {
		t.Fatalf("bad: reported %q; want %q", got, want)
	}
	res, err = checkSpawns([]spawnRoot{{filepath.Join("testdata", "spawns", "good"), spawnBackground}}, exempt)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.findings) != 0 || len(res.stale) != 0 {
		t.Fatalf("good: findings %+v, stale %v; want none", res.findings, res.stale)
	}
	// An owner root refuses a background-only value it cannot vouch for.
	res, err = checkSpawns([]spawnRoot{{filepath.Join("testdata", "spawns", "good", "origin_param.go"), spawnOwner}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.findings) != 1 {
		t.Fatalf("owner root over origin_param.go: findings %+v; want one", res.findings)
	}
}

// The chat engine and the hub import no model leaf (TestBGAI02_HubAndChat…
// in internal/hub), but cmd can hand them a model call as a callback — the
// chat title hook does. Such a callback runs in the background daemon, so it
// must name its origin: owner-marked (WithOwnerStarted) or admitted. A
// callback that is not a func literal (a named func or method value, or a
// constructor's result such as chatRoutingCatalog) is not inspected; every
// model leaf in cmd checks consent per call (BGAI-02), so a missed one is
// refused while paused — it fails closed, never runs unconsented.
func TestBGAI02_HostedCallbacksNameTheirOrigin(t *testing.T) {
	files, err := filepath.Glob(filepath.Join("..", "..", "cmd", "*.go"))
	if err != nil {
		t.Fatal(err)
	}
	findings, err := checkHostedCallbacks(files)
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range findings {
		t.Errorf("%s: %s is a hub or chat-engine callback that calls a model without naming its origin: "+
			"mark its ctx aiconsent.WithOwnerStarted (one owner request) or aiconsent.WithAdmitted", f.pos, f.fn)
	}
}

func TestBGAI02_CallbackCheckerCatchesUnmarkedModelCall(t *testing.T) {
	bad, err := checkHostedCallbacks([]string{filepath.Join("testdata", "spawns", "bad", "callback.go")})
	if err != nil {
		t.Fatal(err)
	}
	if len(bad) != 1 || bad[0].fn != "chatengine.Config.Title" {
		t.Fatalf("bad: %+v; want one finding on chatengine.Config.Title", bad)
	}
	good, err := checkHostedCallbacks([]string{filepath.Join("testdata", "spawns", "good", "callback.go")})
	if err != nil {
		t.Fatal(err)
	}
	if len(good) != 0 {
		t.Fatalf("good: %+v; want none", good)
	}
}

type spawnFinding struct {
	fn, call, pos, want string
}

type spawnResult struct {
	findings []spawnFinding
	stale    []string // exempt keys no spawn matched
}

// checkSpawns parses every non-test .go file under roots (a folder is walked,
// its testdata skipped; a file is read alone).
func checkSpawns(roots []spawnRoot, exempt map[string]string) (spawnResult, error) {
	var res spawnResult
	used := map[string]bool{}
	fset := token.NewFileSet()
	for _, r := range roots {
		files, err := goSources(r.path)
		if err != nil {
			return spawnResult{}, err
		}
		for _, path := range files {
			f, err := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
			if err != nil {
				return spawnResult{}, err
			}
			res.findings = append(res.findings, fileSpawnFindings(fset, f, r.kind, exempt, used)...)
		}
	}
	for k := range exempt {
		if !used[k] {
			res.stale = append(res.stale, k)
		}
	}
	sort.Slice(res.findings, func(i, j int) bool { return res.findings[i].pos < res.findings[j].pos })
	sort.Strings(res.stale)
	return res, nil
}

// goSources is path's non-test .go files: path itself, or the files below it
// (testdata folders skipped).
func goSources(path string) ([]string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() {
		return []string{path}, nil
	}
	var files []string
	err = filepath.WalkDir(path, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if p != path && d.Name() == "testdata" {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(p, ".go") && !strings.HasSuffix(p, "_test.go") {
			files = append(files, p)
		}
		return nil
	})
	return files, err
}

// localImportName is the name path is imported under in f ("" = not imported).
func localImportName(f *ast.File, path string) string {
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

type declBody struct {
	key  string
	node ast.Node
}

// declBodies are f's top-level functions and package-level vars (an
// initialiser may hold a func literal that spawns).
func declBodies(f *ast.File) []declBody {
	var out []declBody
	for _, decl := range f.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			if d.Body != nil {
				out = append(out, declBody{declKey(f.Name.Name, d), d.Body})
			}
		case *ast.GenDecl:
			for _, spec := range d.Specs {
				if vs, ok := spec.(*ast.ValueSpec); ok && len(vs.Values) > 0 {
					out = append(out, declBody{f.Name.Name + "." + vs.Names[0].Name, vs})
				}
			}
		}
	}
	return out
}

// declKey names a top-level declaration as pkg.Func or pkg.(*Type).Method.
func declKey(pkg string, fd *ast.FuncDecl) string {
	if fd.Recv == nil || len(fd.Recv.List) == 0 {
		return pkg + "." + fd.Name.Name
	}
	switch t := fd.Recv.List[0].Type.(type) {
	case *ast.StarExpr:
		if id, ok := t.X.(*ast.Ident); ok {
			return pkg + ".(*" + id.Name + ")." + fd.Name.Name
		}
	case *ast.Ident:
		return pkg + "." + t.Name + "." + fd.Name.Name
	}
	return pkg + "." + fd.Name.Name
}

// isPkgCall reports whether e is a call of pkg.name (pkg the local import
// name; "" never matches).
func isPkgCall(e ast.Expr, pkg string, names ...string) bool {
	call, ok := e.(*ast.CallExpr)
	if !ok {
		return false
	}
	return isPkgSel(call.Fun, pkg, names...)
}

func isPkgSel(e ast.Expr, pkg string, names ...string) bool {
	sel, ok := e.(*ast.SelectorExpr)
	if !ok || pkg == "" {
		return false
	}
	x, ok := sel.X.(*ast.Ident)
	return ok && x.Name == pkg && slices.Contains(names, sel.Sel.Name)
}

// fileSpawnFindings checks every process start of f against kind.
func fileSpawnFindings(fset *token.FileSet, f *ast.File, kind spawnKind, exempt map[string]string, used map[string]bool) []spawnFinding {
	execName, osName := localImportName(f, "os/exec"), localImportName(f, "os")
	consent := localImportName(f, "watchtower/internal/aiconsent")
	if execName == "" && osName == "" {
		return nil
	}
	want := "aiconsent.ChildEnv(ctx), an originEnv parameter or automationAgentEnv(ctx, …)"
	envOK := func(e ast.Expr) bool {
		ok := false
		ast.Inspect(e, func(n ast.Node) bool {
			switch x := n.(type) {
			case *ast.CallExpr:
				if isPkgCall(x, consent, "ChildEnv") || (kind == spawnOwner && isPkgCall(x, consent, "OwnerEnv")) {
					ok = true
				}
				if id, isID := x.Fun.(*ast.Ident); isID && kind == spawnBackground && id.Name == "automationAgentEnv" && len(x.Args) == 2 {
					ok = true
				}
			case *ast.Ident:
				if kind == spawnBackground && x.Name == "originEnv" {
					ok = true
				}
			}
			return !ok
		})
		return ok
	}
	if kind == spawnOwner {
		want = "aiconsent.OwnerEnv(os.Environ()) (one owner request) or aiconsent.ChildEnv(ctx)"
	}

	var out []spawnFinding
	for _, b := range declBodies(f) {
		key := b.key
		// Each spawn is judged by its own env: the Env given to the variable
		// it is assigned to (v.Env = …, or the Env field of the exec.Cmd /
		// os.ProcAttr literal assigned to v), or its own literal's Env field.
		// Variables are keyed by name within one declaration, so two spawns
		// that reuse one name share its Env assignments.
		envOf := map[string][]ast.Expr{}
		spawnVar := map[ast.Node]string{}
		ast.Inspect(b.node, func(n ast.Node) bool {
			as, isAssign := n.(*ast.AssignStmt)
			if !isAssign || len(as.Lhs) != len(as.Rhs) {
				return true
			}
			for i, lhs := range as.Lhs {
				if sel, ok := lhs.(*ast.SelectorExpr); ok && sel.Sel.Name == "Env" {
					if id, ok := sel.X.(*ast.Ident); ok {
						envOf[id.Name] = append(envOf[id.Name], as.Rhs[i])
					}
				}
				id, ok := lhs.(*ast.Ident)
				if !ok {
					continue
				}
				rhs := unwrapAddr(as.Rhs[i])
				spawnVar[rhs] = id.Name
				if cl, ok := rhs.(*ast.CompositeLit); ok {
					if e := litEnvField(cl); e != nil {
						envOf[id.Name] = append(envOf[id.Name], e)
					}
				}
			}
			return true
		})
		// envOKFor: the spawn's own literal Env field, else its variable's.
		envOKFor := func(n ast.Node) bool {
			if cl, ok := n.(*ast.CompositeLit); ok {
				if e := litEnvField(cl); e != nil && envOK(e) {
					return true
				}
			}
			name, ok := spawnVar[n]
			return ok && slices.ContainsFunc(envOf[name], envOK)
		}
		ast.Inspect(b.node, func(n ast.Node) bool {
			var (
				call    string
				progArg ast.Expr
				ok      bool
			)
			switch x := n.(type) {
			case *ast.CallExpr:
				switch {
				case isPkgSel(x.Fun, execName, "Command") && len(x.Args) > 0:
					call, progArg = "exec.Command", x.Args[0]
					ok = envOKFor(x)
				case isPkgSel(x.Fun, execName, "CommandContext") && len(x.Args) > 1:
					call, progArg = "exec.CommandContext", x.Args[1]
					ok = envOKFor(x)
				case isPkgSel(x.Fun, osName, "StartProcess") && len(x.Args) > 2:
					// Judged by its own attr argument: a literal, or the
					// variable holding one.
					call, progArg = "os.StartProcess", x.Args[0]
					attr := unwrapAddr(x.Args[2])
					if id, isID := attr.(*ast.Ident); isID {
						ok = slices.ContainsFunc(envOf[id.Name], envOK)
					} else {
						ok = envOKFor(attr)
					}
				default:
					return true
				}
			case *ast.CompositeLit:
				if !isPkgSel(x.Type, execName, "Cmd") {
					return true
				}
				call = "exec.Cmd{}"
				ok = envOKFor(x)
			default:
				return true
			}
			if lit, isLit := progArg.(*ast.BasicLit); isLit && lit.Kind == token.STRING {
				if prog, err := strconv.Unquote(lit.Value); err == nil {
					if _, ex := exempt[prog]; ex {
						used[prog] = true
						return true
					}
				}
			}
			if _, ex := exempt[key]; ex {
				used[key] = true
				return true
			}
			if !ok {
				out = append(out, spawnFinding{fn: key, call: call, pos: fset.Position(n.Pos()).String(), want: want})
			}
			return true
		})
	}
	return out
}

// isHostedPackage reports whether path is a package whose config types the
// daemon fills with callbacks it then runs in its own (background) process.
func isHostedPackage(path string) bool {
	return path == "watchtower/internal/chatengine" || path == "watchtower/internal/hub" ||
		strings.HasPrefix(path, "watchtower/internal/hub/")
}

// modelCallMarkers and modelLeafImports mark a callback body as reaching a
// model: a name of a generator or provider entry point, or a selector into a
// model-leaf package (TestBGAI02_HubAndChat…'s list).
var modelCallMarkers = []string{"Generat", "QuerySync"}

var modelLeafImports = []string{
	"watchtower/internal/ai", "watchtower/internal/digest", "watchtower/internal/agentloop",
	"watchtower/internal/providers/transport", "watchtower/internal/claude", "watchtower/internal/codex",
}

// checkHostedCallbacks finds the func literals given to a field of a hosted
// package's composite literal whose body reaches a model and does not mark
// its ctx with an origin.
func checkHostedCallbacks(files []string) ([]spawnFinding, error) {
	fset := token.NewFileSet()
	var out []spawnFinding
	for _, path := range files {
		if strings.HasSuffix(path, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
		if err != nil {
			return nil, err
		}
		hosted := map[string]bool{}
		var leaves []string
		for _, imp := range f.Imports {
			p, _ := strconv.Unquote(imp.Path.Value)
			name := p[strings.LastIndex(p, "/")+1:]
			if imp.Name != nil {
				name = imp.Name.Name
			}
			if isHostedPackage(p) {
				hosted[name] = true
			}
			if slices.Contains(modelLeafImports, p) {
				leaves = append(leaves, name)
			}
		}
		if len(hosted) == 0 {
			continue
		}
		consent := localImportName(f, "watchtower/internal/aiconsent")
		ast.Inspect(f, func(n ast.Node) bool {
			cl, ok := n.(*ast.CompositeLit)
			if !ok {
				return true
			}
			sel, ok := cl.Type.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			pkg, ok := sel.X.(*ast.Ident)
			if !ok || !hosted[pkg.Name] {
				return true
			}
			for _, el := range cl.Elts {
				kv, ok := el.(*ast.KeyValueExpr)
				if !ok {
					continue
				}
				lit, ok := kv.Value.(*ast.FuncLit)
				if !ok {
					continue
				}
				if callbackReachesModel(lit, leaves) && !callbackNamesOrigin(lit, consent) {
					field := fmt.Sprint(kv.Key)
					out = append(out, spawnFinding{fn: pkg.Name + "." + sel.Sel.Name + "." + field, pos: fset.Position(kv.Pos()).String()})
				}
			}
			return true
		})
	}
	return out, nil
}

func callbackReachesModel(lit *ast.FuncLit, leaves []string) bool {
	found := false
	ast.Inspect(lit.Body, func(n ast.Node) bool {
		switch x := n.(type) {
		case *ast.Ident:
			for _, m := range modelCallMarkers {
				if strings.Contains(x.Name, m) {
					found = true
				}
			}
		case *ast.SelectorExpr:
			if id, ok := x.X.(*ast.Ident); ok && slices.Contains(leaves, id.Name) {
				found = true
			}
		}
		return !found
	})
	return found
}

func callbackNamesOrigin(lit *ast.FuncLit, consent string) bool {
	found := false
	ast.Inspect(lit.Body, func(n ast.Node) bool {
		if isPkgCall(asExpr(n), consent, "WithOwnerStarted", "WithAdmitted") {
			found = true
		}
		return !found
	})
	return found
}

// unwrapAddr is e without a leading &.
func unwrapAddr(e ast.Expr) ast.Expr {
	if u, ok := e.(*ast.UnaryExpr); ok && u.Op == token.AND {
		return u.X
	}
	return e
}

// litEnvField is the Env field's value of a composite literal (nil = none).
func litEnvField(cl *ast.CompositeLit) ast.Expr {
	for _, el := range cl.Elts {
		if kv, ok := el.(*ast.KeyValueExpr); ok {
			if k, ok := kv.Key.(*ast.Ident); ok && k.Name == "Env" {
				return kv.Value
			}
		}
	}
	return nil
}

func asExpr(n ast.Node) ast.Expr {
	e, _ := n.(ast.Expr)
	return e
}
