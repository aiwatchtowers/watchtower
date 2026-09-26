package cmd

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// TestPromptStoreWiring_EveryPipelineConstructionIsWired is a property scan,
// not an enumeration: it discovers which packages under internal/ expose a
// SetPromptStore seam, discovers that package's constructors by return type,
// and then requires every construction of such a pipeline anywhere in cmd/ to
// hand it a prompt store in the same function body.
//
// The property it pins is the one the audit found broken: a pipeline can grow
// a SetPromptStore method, have its prompt ids registered in
// internal/prompts, be offered as a tunable row in Settings → Prompts — and
// still read the compiled-in default forever, because no caller ever wired
// the store. briefing, digest, tracks and guide sat in exactly that state
// from the day each seam was added (verify-daemon.md Item A). An enumeration
// guard listing today's call sites would not have caught them, and would not
// catch the fifth pipeline added tomorrow; this scan fails the day such a
// call site is written.
//
// The scan is a deliberately narrow syntactic approximation (no type
// checking), and every shape it does not recognise fails LOUDLY rather than
// passing silently: a construction whose result is not bound to a plain
// identifier is reported as a failure telling the author to bind it, because
// the scan cannot otherwise prove the store was wired. Over-flagging is the
// intended bias — a false negative here is the exact bug being guarded
// against. The one acknowledged narrowness: wiring is matched by identifier
// name within a single function body, so a body that shadows one pipeline
// variable's name with another could in principle mask a miss. No such shape
// exists in cmd/ today, and the failure mode is visible in the diff that
// would introduce it.
func TestPromptStoreWiring_EveryPipelineConstructionIsWired(t *testing.T) {
	root := repoRootForPromptScan(t)

	internalFiles := parseGoFilesUnder(t, root, filepath.Join(root, "internal"))
	ctors := discoverPipelineConstructors(internalFiles)

	// Coverage floor #1: discovery itself. A scan whose discovery silently
	// found nothing (internal/ moved, the seam renamed, a broken walk) finds
	// zero constructions to check and therefore reports zero failures —
	// passing for exactly the wrong reason.
	pkgs := map[string]bool{}
	for key := range ctors {
		pkgs[key.pkg] = true
	}
	if len(pkgs) < minPromptStorePackages {
		t.Fatalf("discovered SetPromptStore on only %d packages under internal/, want at least %d — discovery is probably broken (resolved repo root %q)", len(pkgs), minPromptStorePackages, root)
	}
	// Anchor: the four pipelines this scan was written for. Discovery that
	// returns a plausible-looking package count but misses these has drifted.
	for _, want := range []string{"briefing", "digest", "tracks", "guide"} {
		if !pkgs[want] {
			t.Fatalf("discovery did not find a SetPromptStore seam in package %q — found %v", want, sortedKeys(pkgs))
		}
	}

	cmdFiles := parseGoFilesUnder(t, root, filepath.Join(root, "cmd"))
	if len(cmdFiles) < minCmdFilesWalked {
		t.Fatalf("walked only %d non-test .go files under cmd/, want at least %d — the scan may be looking at the wrong root (%q)", len(cmdFiles), minCmdFilesWalked, root)
	}

	var failures []string
	constructions := 0
	for _, f := range cmdFiles {
		fileFailures, found := scanFileForPipelineWiring(f, ctors)
		failures = append(failures, fileFailures...)
		constructions += found
	}

	// Coverage floor #2: the cmd/ side. Same reasoning as floor #1, but for
	// the half of the scan that can regress independently (a renamed
	// constructor, an import alias the scan does not follow).
	if constructions < minPipelineConstructions {
		t.Fatalf("found only %d pipeline constructions in cmd/, want at least %d — a scan that finds too few is as broken as one that finds none", constructions, minPipelineConstructions)
	}

	for _, f := range failures {
		t.Error(f)
	}
	t.Logf("prompt-store wiring scan: %d constructor signatures across %d packages, %d cmd/ files walked, %d constructions checked",
		len(ctors), len(pkgs), len(cmdFiles), constructions)
}

// minPromptStorePackages, minCmdFilesWalked and minPipelineConstructions are
// coverage floors, not exact counts. As of the 2026-09-23 targets.extract/
// targets.link wiring, discovery finds the SetPromptStore seam on
// 11 packages (briefing, catchup, dayplan, digest, guide, ideas, meeting,
// memory, reactioncmd, targets, tracks — "inbox" dropped off this list when
// the 2026-09-14 inbox demolition removed its last AI call and, with it, its
// SetPromptStore seam), walks 60 non-test .go files under cmd/, and checks
// 35 constructions (all four numbers are logged on every run by the t.Logf
// above). The floors sit below those measured values so ordinary growth
// never trips them, while a walk that silently covers nothing fails loudly
// instead of reporting a false "no problems found". Raise them deliberately
// — with the new measured numbers recorded here — never lower them to make
// a failing run pass.
const (
	minPromptStorePackages   = 9
	minCmdFilesWalked        = 40
	minPipelineConstructions = 25
)

// ctorKey identifies one pipeline constructor by the package clause it lives
// in and its function name, e.g. {pkg: "memory", name: "NewPipeline"}. cmd/
// does not alias these imports, so matching a selector's package identifier
// text against the package clause is sound here (the same assumption
// internal/digest/tier_scan_test.go makes).
type ctorKey struct {
	pkg  string
	name string
}

// discoverPipelineConstructors finds, for every package under internal/ that
// defines a SetPromptStore method, every package-level function returning a
// pointer to that method's receiver type. Deriving the constructor set from
// the return type rather than from the name "New" is what lets the scan cover
// memory.NewPipeline and any future constructor without a hand-maintained
// list.
func discoverPipelineConstructors(files []parsedGoFile) map[ctorKey]bool {
	receivers := collectPromptStoreReceivers(files)
	return collectConstructorsForReceivers(files, receivers)
}

// collectPromptStoreReceivers walks every file's declarations and returns,
// per package, the set of receiver type names that carry a SetPromptStore
// method.
func collectPromptStoreReceivers(files []parsedGoFile) map[string]map[string]bool {
	receivers := map[string]map[string]bool{}
	for _, f := range files {
		for _, decl := range f.file.Decls {
			fd, ok := decl.(*ast.FuncDecl)
			if !ok || fd.Name.Name != "SetPromptStore" || fd.Recv == nil || len(fd.Recv.List) == 0 {
				continue
			}
			name, ok := receiverTypeName(fd.Recv.List[0].Type)
			if !ok {
				continue
			}
			if receivers[f.pkg] == nil {
				receivers[f.pkg] = map[string]bool{}
			}
			receivers[f.pkg][name] = true
		}
	}
	return receivers
}

// collectConstructorsForReceivers finds every exported, receiverless
// function whose return type is a pointer to one of the given per-package
// prompt-store-bearing receiver types.
func collectConstructorsForReceivers(files []parsedGoFile, receivers map[string]map[string]bool) map[ctorKey]bool {
	ctors := map[ctorKey]bool{}
	for _, f := range files {
		types := receivers[f.pkg]
		if len(types) == 0 {
			continue
		}
		for _, decl := range f.file.Decls {
			fd, ok := decl.(*ast.FuncDecl)
			if !ok || fd.Recv != nil || fd.Type.Results == nil || !ast.IsExported(fd.Name.Name) {
				continue
			}
			if constructorReturnsAny(fd, types) {
				ctors[ctorKey{pkg: f.pkg, name: fd.Name.Name}] = true
			}
		}
	}
	return ctors
}

// constructorReturnsAny reports whether fd returns a pointer to one of the
// given type names among its results.
func constructorReturnsAny(fd *ast.FuncDecl, types map[string]bool) bool {
	for _, res := range fd.Type.Results.List {
		star, ok := res.Type.(*ast.StarExpr)
		if !ok {
			continue
		}
		ident, ok := star.X.(*ast.Ident)
		if ok && types[ident.Name] {
			return true
		}
	}
	return false
}

// receiverTypeName unwraps a method receiver (`p *Pipeline` or `p Pipeline`)
// to its bare type name.
func receiverTypeName(expr ast.Expr) (string, bool) {
	if star, ok := expr.(*ast.StarExpr); ok {
		expr = star.X
	}
	ident, ok := expr.(*ast.Ident)
	if !ok {
		return "", false
	}
	return ident.Name, true
}

// scanFileForPipelineWiring checks every function body in one cmd/ file.
// Returns one failure string per unwired (or unbindable) construction, plus
// the number of constructions seen in this file whether or not they passed —
// the caller uses that count for the coverage floor.
func scanFileForPipelineWiring(f parsedGoFile, ctors map[ctorKey]bool) ([]string, int) {
	var failures []string
	total := 0
	for _, body := range functionBodies(f.file) {
		bodyFailures, found := scanBodyForPipelineWiring(f, body, ctors)
		failures = append(failures, bodyFailures...)
		total += found
	}
	return failures, total
}

// scanBodyForPipelineWiring applies the wiring rule to one function body: a
// construction must be bound to a plain identifier, and that identifier must
// have SetPromptStore called on it somewhere in the same body.
func scanBodyForPipelineWiring(f parsedGoFile, body *ast.BlockStmt, ctors map[ctorKey]bool) ([]string, int) {
	bound := map[*ast.CallExpr]string{} // construction -> variable it was bound to
	all := []*ast.CallExpr{}            // every construction, bound or not
	wired := map[string]bool{}          // variables that got SetPromptStore
	ast.Inspect(body, func(n ast.Node) bool {
		switch node := n.(type) {
		case *ast.AssignStmt:
			recordBindings(node.Lhs, node.Rhs, ctors, bound)
		case *ast.ValueSpec:
			recordBindings(identsAsExprs(node.Names), node.Values, ctors, bound)
		case *ast.CallExpr:
			if isPipelineConstructor(node, ctors) {
				all = append(all, node)
			}
			if name, ok := setPromptStoreReceiver(node); ok {
				wired[name] = true
			}
		}
		return true
	})

	var failures []string
	for _, call := range all {
		loc := f.relPath + ":" + strconv.Itoa(f.fset.Position(call.Pos()).Line)
		name, ok := bound[call]
		if !ok {
			failures = append(failures, loc+" constructs a prompt-store pipeline whose result this scan cannot follow"+
				" — bind it to a variable and call x.SetPromptStore(prompts.New(database, nil)) in the same function")
			continue
		}
		if !wired[name] {
			failures = append(failures, loc+" constructs a prompt-store pipeline as "+strconv.Quote(name)+
				" but never calls "+name+".SetPromptStore(...) in the same function — the pipeline will read compiled-in default"+
				" prompts and ignore every Settings → Prompts edit")
		}
	}
	return failures, len(all)
}

// recordBindings pairs `x, y := ctor(), other()` style left- and right-hand
// sides, noting which identifier each pipeline construction was bound to. A
// blank identifier is deliberately left unbound so it reports as unfollowable
// rather than silently passing.
func recordBindings(lhs, rhs []ast.Expr, ctors map[ctorKey]bool, bound map[*ast.CallExpr]string) {
	if len(lhs) != len(rhs) {
		return
	}
	for i, r := range rhs {
		call, ok := r.(*ast.CallExpr)
		if !ok || !isPipelineConstructor(call, ctors) {
			continue
		}
		ident, ok := lhs[i].(*ast.Ident)
		if !ok || ident.Name == "_" {
			continue
		}
		bound[call] = ident.Name
	}
}

func identsAsExprs(names []*ast.Ident) []ast.Expr {
	out := make([]ast.Expr, 0, len(names))
	for _, n := range names {
		out = append(out, n)
	}
	return out
}

// isPipelineConstructor reports whether call is `pkg.Ctor(...)` for a
// discovered (package, constructor) pair.
func isPipelineConstructor(call *ast.CallExpr, ctors map[ctorKey]bool) bool {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok {
		return false
	}
	return ctors[ctorKey{pkg: pkgIdent.Name, name: sel.Sel.Name}]
}

// setPromptStoreReceiver reports the receiver identifier of an
// `x.SetPromptStore(...)` call.
func setPromptStoreReceiver(call *ast.CallExpr) (string, bool) {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel.Name != "SetPromptStore" {
		return "", false
	}
	ident, ok := sel.X.(*ast.Ident)
	if !ok {
		return "", false
	}
	return ident.Name, true
}

// functionBodies returns every scope the wiring rule applies to: each
// top-level function/method body, plus each package-level `var x = func(...)`
// literal (the newDayPlanPipelineFactory / newMemoryPipelineFactory seam
// shape, which is not a FuncDecl). A function literal nested inside a
// FuncDecl needs no separate entry — it is already inside that body.
func functionBodies(file *ast.File) []*ast.BlockStmt {
	var out []*ast.BlockStmt
	for _, decl := range file.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			if d.Body != nil {
				out = append(out, d.Body)
			}
		case *ast.GenDecl:
			if d.Tok != token.VAR {
				continue
			}
			for _, spec := range d.Specs {
				vs, ok := spec.(*ast.ValueSpec)
				if !ok {
					continue
				}
				for _, v := range vs.Values {
					if lit, ok := v.(*ast.FuncLit); ok && lit.Body != nil {
						out = append(out, lit.Body)
					}
				}
			}
		}
	}
	return out
}

type parsedGoFile struct {
	relPath string
	file    *ast.File
	fset    *token.FileSet
	pkg     string
}

// parseGoFilesUnder parses every non-test .go file under dir, recursively.
func parseGoFilesUnder(t *testing.T, root, dir string) []parsedGoFile {
	t.Helper()
	var out []parsedGoFile
	err := filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		fset := token.NewFileSet()
		f, perr := parser.ParseFile(fset, path, nil, 0)
		if perr != nil {
			t.Fatalf("parsing %s: %v", path, perr)
		}
		rel, rerr := filepath.Rel(root, path)
		if rerr != nil {
			rel = path
		}
		out = append(out, parsedGoFile{relPath: rel, file: f, fset: fset, pkg: f.Name.Name})
		return nil
	})
	if err != nil {
		t.Fatalf("walking %s: %v", dir, err)
	}
	return out
}

// repoRootForPromptScan resolves the repository root relative to this test
// file, so the scan works regardless of the working directory.
func repoRootForPromptScan(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed resolving this test file's path")
	}
	// cmd/prompt_store_scan_test.go -> repo root is one directory up.
	root := filepath.Join(filepath.Dir(thisFile), "..")
	if _, err := os.Stat(filepath.Join(root, "go.mod")); err != nil {
		t.Fatalf("resolved repo root %q does not contain go.mod: %v", root, err)
	}
	return root
}

func sortedKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
