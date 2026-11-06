package transporttest

import (
	"bufio"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// LLMTRANSPORT-01 — a consumer decides by capability, never by transport
// identity. Only the adapters (spec §1) may name a transport.

// modulePath is the Go module of the repository (go.mod).
const modulePath = "watchtower"

// adapterDirs are the adapter packages, relative to the repository root;
// every package under them is an adapter too. internal/transporttest holds
// the contract suite's fakes, which name every transport by design.
var adapterDirs = []string{
	"internal/agentloop",
	"internal/ai",
	"internal/codex",
	"internal/digest",
	"internal/ollama",
	"internal/providers",
	"internal/sessionagent",
	"internal/transporttest",
}

// adapterFiles are the adapter files inside consumer packages.
var adapterFiles = []string{
	"cmd/transport_wiring.go",
	"internal/chat/attachments.go",
	"internal/chat/claude_backend.go",
	"internal/chat/claude_translate.go",
}

// capabilityFiles declare which capabilities each agent kind has: the only
// places outside the adapters where a kind maps to its caps. Since A5 the
// session caps are internal/sessionagent's (an adapter), so none is left.
var capabilityFiles = []string{}

// plannedAdapters are adapter paths the transport independence plan creates
// later. Only these may be missing; once one exists the test asks for its
// removal from this set, so a typo in the lists above cannot hide.
var plannedAdapters = map[string]bool{}

// transportNames are the string literals that name a transport.
var transportNames = map[string]bool{"claude": true, "codex": true, "ollama": true, "http": true}

// agentKindPath is the package whose Claude/Codex constants name a
// Workbench agent's transport.
const agentKindPath = modulePath + "/internal/agentkind"

const allowFile = "testdata/llmtransport_allow.txt"

// TestLLMTRANSPORT01_NoTransportNamesOutsideAdapters fails on a transport
// name check outside the adapters that the baseline does not list: a
// comparison, switch case or slices.Contains/Index membership test against
// "claude"/"codex"/"ollama"/"http" or agentkind.Claude/Codex (also inside a
// conversion such as string(agentkind.Codex)), or a type assertion to a
// concrete adapter type.
// BEHAVIOR LLMTRANSPORT-01 — see docs/inventory/llm-transport.md
func TestLLMTRANSPORT01_NoTransportNamesOutsideAdapters(t *testing.T) {
	hits := repoHits(t)
	allow := readAllow(t)
	for _, key := range slices.Sorted(maps.Keys(hits)) {
		if n, allowed := hits[key], allow[key].count; n > allowed {
			t.Errorf("%s: %d transport name check(s), baseline allows %d. Decide by a capability "+
				"(providers.Capabilities) or move the code into an adapter; a new baseline entry needs "+
				"the owner's approval (LLMTRANSPORT-01)", key, n, allowed)
		}
	}
}

// TestLLMTRANSPORT01_BaselineOnlyShrinks fails on a baseline entry that no
// longer matches: delete it or lower its count.
// BEHAVIOR LLMTRANSPORT-01 — see docs/inventory/llm-transport.md
func TestLLMTRANSPORT01_BaselineOnlyShrinks(t *testing.T) {
	hits := repoHits(t)
	for key, e := range readAllow(t) {
		if got := hits[key]; got < e.count {
			t.Errorf("%s (line %d) allows %d hit(s) but %d remain: lower the count or delete the entry, "+
				"the baseline only shrinks", key, e.line, e.count, got)
		}
	}
}

// TestLLMTRANSPORT01_CatchesANewNameCheck runs the checker over a synthetic
// consumer: every kind of name check is flagged, a capability probe is not.
func TestLLMTRANSPORT01_CatchesANewNameCheck(t *testing.T) {
	const src = `package consumer

import (
	"slices"

	"watchtower/internal/agentkind"
	"watchtower/internal/codex"
	kind "watchtower/internal/digest"
)

func pick(provider string, k agentkind.Kind, g any) int {
	if provider == "codex" {
		return 1
	}
	if "ollama" != provider {
		return 2
	}
	switch provider {
	case "claude", "http":
		return 3
	case "openai":
		return 9
	}
	if k == agentkind.Codex || provider == string(agentkind.Claude) || (k) == (agentkind.Kind("codex")) {
		return 4
	}
	if _, ok := g.(*codex.Client); ok {
		return 5
	}
	switch g.(type) {
	case *codex.Client:
		return 6
	case *chatBackend:
		return 8
	}
	if _, ok := g.(kind.ImageCapable); ok {
		return 7
	}
	if slices.Contains([]string{"claude", "openai", "ollama"}, provider) {
		return 10
	}
	return 0
}

var routed = func(p string) bool { return p == "claude" }

func (s *Server) other(p string) bool { return p == "codex" && p != "other" }
`
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "consumer.go", src, parser.SkipObjectResolution)
	if err != nil {
		t.Fatal(err)
	}
	concrete := map[string]bool{
		modulePath + "/internal/codex.Client":  true,
		modulePath + "/x/consumer.chatBackend": true,
	}
	got := map[string]int{}
	for _, h := range fileHits(f, "x/consumer/consumer.go", modulePath+"/x/consumer", concrete) {
		got[h]++
	}
	const file = "x/consumer/consumer.go | "
	want := map[string]int{
		file + `pick | "codex"`:              2, // == "codex" and agentkind.Kind("codex")
		file + `pick | "ollama"`:             2,
		file + `pick | "claude"`:             2,
		file + `pick | "http"`:               1,
		file + `pick | agentkind.Codex`:      1,
		file + `pick | agentkind.Claude`:     1,
		file + `pick | assert *codex.Client`: 2,
		file + `pick | assert *chatBackend`:  1,
		file + `var routed | "claude"`:       1,
		file + `(*Server).other | "codex"`:   1,
	}
	if !maps.Equal(got, want) {
		t.Fatalf("hits:\n  %v\nwant:\n  %v", got, want)
	}
}

var (
	repoScanOnce sync.Once
	repoScan     map[string]int
	repoScanErr  error
)

// repoHits scans the repository once per test binary; both guards read it.
func repoHits(t *testing.T) map[string]int {
	t.Helper()
	root := repoRoot(t)
	repoScanOnce.Do(func() { repoScan, repoScanErr = scanRepo(root) })
	if repoScanErr != nil {
		t.Fatal(repoScanErr)
	}
	return repoScan
}

// scanRepo returns every name check outside the adapters, keyed
// "<file> | <func> | <what>", with its count.
func scanRepo(root string) (map[string]int, error) {
	if err := checkAdapterPaths(root); err != nil {
		return nil, err
	}
	concrete, err := concreteAdapterTypes(root)
	if err != nil {
		return nil, err
	}
	fset := token.NewFileSet()
	hits := map[string]int{}
	files := 0
	for _, dir := range []string{"cmd", "internal"} {
		err := walkGo(root, dir, func(rel string, d fs.DirEntry) bool {
			return d.Name() == "testdata" || isAdapterDir(rel)
		}, func(rel string) error {
			if isAdapterFile(rel) || slices.Contains(capabilityFiles, rel) {
				return nil
			}
			f, err := parser.ParseFile(fset, filepath.Join(root, rel), nil, parser.SkipObjectResolution)
			if err != nil {
				return err
			}
			files++
			for _, h := range fileHits(f, rel, modulePath+"/"+filepath.ToSlash(filepath.Dir(rel)), concrete) {
				hits[h]++
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	if files == 0 {
		return nil, os.ErrNotExist
	}
	return hits, nil
}

// walkGo calls visit with the repository-relative slash path of every
// non-test .go file under root/dir; skipDir prunes a directory.
func walkGo(root, dir string, skipDir func(rel string, d fs.DirEntry) bool, visit func(rel string) error) error {
	return filepath.WalkDir(filepath.Join(root, dir), func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if d.IsDir() {
			if rel != dir && skipDir(rel, d) {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(rel, ".go") || strings.HasSuffix(rel, "_test.go") {
			return nil
		}
		return visit(rel)
	})
}

// checkAdapterPaths fails on a listed adapter path that does not exist,
// unless it is planned, and on a planned path that now exists.
func checkAdapterPaths(root string) error {
	for _, p := range slices.Concat(adapterDirs, adapterFiles, capabilityFiles) {
		_, err := os.Stat(filepath.Join(root, p))
		switch {
		case err == nil && plannedAdapters[p]:
			return &pathError{p, "exists now: remove it from plannedAdapters"}
		case os.IsNotExist(err) && !plannedAdapters[p]:
			return &pathError{p, "is listed as an adapter but does not exist"}
		case err != nil && !os.IsNotExist(err):
			return err
		}
	}
	return nil
}

type pathError struct{ path, msg string }

func (e *pathError) Error() string { return e.path + " " + e.msg }

func isAdapterDir(rel string) bool {
	for _, d := range adapterDirs {
		if rel == d || strings.HasPrefix(rel, d+"/") {
			return true
		}
	}
	return false
}

func isAdapterFile(rel string) bool { return slices.Contains(adapterFiles, rel) }

// concreteAdapterTypes lists "<import path>.<Type>" for every non-interface
// type the adapter packages and adapter files declare.
func concreteAdapterTypes(root string) (map[string]bool, error) {
	out := map[string]bool{}
	fset := token.NewFileSet()
	collect := func(rel string) error {
		f, err := parser.ParseFile(fset, filepath.Join(root, rel), nil, parser.SkipObjectResolution)
		if err != nil {
			return err
		}
		pkgPath := modulePath + "/" + filepath.ToSlash(filepath.Dir(rel))
		for _, name := range concreteTypes(f) {
			out[pkgPath+"."+name] = true
		}
		return nil
	}
	for _, dir := range adapterDirs {
		if plannedAdapters[dir] {
			continue
		}
		skip := func(_ string, d fs.DirEntry) bool { return d.Name() == "testdata" }
		if err := walkGo(root, dir, skip, collect); err != nil {
			return nil, err
		}
	}
	for _, file := range adapterFiles {
		if plannedAdapters[file] {
			continue
		}
		if err := collect(file); err != nil {
			return nil, err
		}
	}
	return out, nil
}

func concreteTypes(f *ast.File) []string {
	var out []string
	for _, decl := range f.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok || gd.Tok != token.TYPE {
			continue
		}
		for _, spec := range gd.Specs {
			ts := spec.(*ast.TypeSpec)
			if _, iface := ts.Type.(*ast.InterfaceType); !iface {
				out = append(out, ts.Name.Name)
			}
		}
	}
	return out
}

// fileScope resolves names in one file: its import names and its own package.
type fileScope struct {
	imports     map[string]string // local name → import path
	pkgPath     string
	concrete    map[string]bool
	inAgentKind bool // bare Claude/Codex are the kinds (the agentkind package itself)
}

// fileHits returns one key per name check in f (rel is its repository path,
// pkgPath its import path).
func fileHits(f *ast.File, rel, pkgPath string, concrete map[string]bool) []string {
	s := fileScope{imports: map[string]string{}, pkgPath: pkgPath, concrete: concrete, inAgentKind: pkgPath == agentKindPath}
	for _, imp := range f.Imports {
		p, _ := strconv.Unquote(imp.Path.Value)
		name := p[strings.LastIndex(p, "/")+1:]
		if imp.Name != nil {
			name = imp.Name.Name
		}
		s.imports[name] = p
	}
	var out []string
	for _, decl := range f.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			out = s.appendHits(out, rel+" | "+funcName(d)+" | ", d)
		case *ast.GenDecl:
			for _, spec := range d.Specs {
				if vs, ok := spec.(*ast.ValueSpec); ok {
					out = s.appendHits(out, rel+" | var "+valueNames(vs)+" | ", vs)
				}
			}
		}
	}
	return out
}

func valueNames(vs *ast.ValueSpec) string {
	names := make([]string, 0, len(vs.Names))
	for _, n := range vs.Names {
		names = append(names, n.Name)
	}
	return strings.Join(names, ",")
}

// appendHits appends prefix+what for every name check under n.
func (s fileScope) appendHits(out []string, prefix string, n ast.Node) []string {
	add := func(what string) {
		if what != "" {
			out = append(out, prefix+what)
		}
	}
	ast.Inspect(n, func(n ast.Node) bool {
		switch x := n.(type) {
		case *ast.BinaryExpr:
			if x.Op == token.EQL || x.Op == token.NEQ {
				if w := s.nameOf(x.X); w != "" {
					add(w)
				} else {
					add(s.nameOf(x.Y))
				}
			}
		case *ast.SwitchStmt:
			s.eachCase(x.Body, func(e ast.Expr) { add(s.nameOf(e)) })
		case *ast.TypeAssertExpr:
			if x.Type != nil {
				add(s.assertOf(x.Type))
			}
		case *ast.TypeSwitchStmt:
			s.eachCase(x.Body, func(e ast.Expr) { add(s.assertOf(e)) })
		case *ast.CallExpr:
			for _, w := range s.membership(x) {
				add(w)
			}
		}
		return true
	})
	return out
}

func (fileScope) eachCase(body *ast.BlockStmt, fn func(ast.Expr)) {
	for _, c := range body.List {
		for _, e := range c.(*ast.CaseClause).List {
			fn(e)
		}
	}
}

// nameOf names e when it is a transport name: a literal, an agentkind
// constant, either one in parentheses or inside a one-argument conversion.
func (s fileScope) nameOf(e ast.Expr) string {
	switch x := e.(type) {
	case *ast.ParenExpr:
		return s.nameOf(x.X)
	case *ast.CallExpr:
		if len(x.Args) == 1 && isTypeName(x.Fun) {
			return s.nameOf(x.Args[0])
		}
	case *ast.BasicLit:
		if x.Kind == token.STRING {
			if v, err := strconv.Unquote(x.Value); err == nil && transportNames[v] {
				return strconv.Quote(v)
			}
		}
	case *ast.SelectorExpr:
		if id, ok := x.X.(*ast.Ident); ok && s.imports[id.Name] == agentKindPath && isKindConst(x.Sel.Name) {
			return "agentkind." + x.Sel.Name
		}
	case *ast.Ident:
		if s.inAgentKind && isKindConst(x.Name) {
			return "agentkind." + x.Name
		}
	}
	return ""
}

// isTypeName reports whether a call is a conversion to a kind string:
// string(x), Kind(x) or agentkind.Kind(x).
func isTypeName(fun ast.Expr) bool {
	switch f := fun.(type) {
	case *ast.Ident:
		return f.Name == "string" || f.Name == "Kind"
	case *ast.SelectorExpr:
		_, ok := f.X.(*ast.Ident)
		return ok && f.Sel.Name == "Kind"
	}
	return false
}

func isKindConst(name string) bool { return name == "Claude" || name == "Codex" }

// membership names every transport name in the literal list of a
// slices.Contains or slices.Index call.
func (s fileScope) membership(call *ast.CallExpr) []string {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || len(call.Args) != 2 || (sel.Sel.Name != "Contains" && sel.Sel.Name != "Index") {
		return nil
	}
	if id, ok := sel.X.(*ast.Ident); !ok || s.imports[id.Name] != "slices" {
		return nil
	}
	lit, ok := call.Args[0].(*ast.CompositeLit)
	if !ok {
		return nil
	}
	var out []string
	for _, e := range lit.Elts {
		if w := s.nameOf(e); w != "" {
			out = append(out, w)
		}
	}
	return out
}

// assertOf names a type-assertion target that is a concrete adapter type,
// in another package (*codex.Client) or in this one (*claudeBackend).
func (s fileScope) assertOf(e ast.Expr) string {
	star := ""
	if st, ok := e.(*ast.StarExpr); ok {
		star, e = "*", st.X
	}
	switch x := e.(type) {
	case *ast.SelectorExpr:
		id, ok := x.X.(*ast.Ident)
		if !ok {
			return ""
		}
		if p := s.imports[id.Name]; s.concrete[p+"."+x.Sel.Name] {
			return "assert " + star + p[strings.LastIndex(p, "/")+1:] + "." + x.Sel.Name
		}
	case *ast.Ident:
		if s.concrete[s.pkgPath+"."+x.Name] {
			return "assert " + star + x.Name
		}
	}
	return ""
}

func funcName(d *ast.FuncDecl) string {
	if d.Recv == nil || len(d.Recv.List) == 0 {
		return d.Name.Name
	}
	typ := d.Recv.List[0].Type
	star := false
	if s, ok := typ.(*ast.StarExpr); ok {
		star, typ = true, s.X
	}
	switch x := typ.(type) {
	case *ast.IndexExpr:
		typ = x.X
	case *ast.IndexListExpr:
		typ = x.X
	}
	name := "?"
	if id, ok := typ.(*ast.Ident); ok {
		name = id.Name
	}
	if star {
		return "(*" + name + ")." + d.Name.Name
	}
	return name + "." + d.Name.Name
}

type allowEntry struct {
	count int
	line  int
}

// readAllow parses the baseline: "<file> | <func> | <what> | <count> | <reason>"
// per line; blank lines and lines starting with # are skipped. A missing
// reason, a bad count or a duplicate key fails.
func readAllow(t *testing.T) map[string]allowEntry {
	t.Helper()
	f, err := os.Open(allowFile)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	out := map[string]allowEntry{}
	sc := bufio.NewScanner(f)
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, " | ", 5)
		if len(parts) != 5 || strings.TrimSpace(parts[4]) == "" {
			t.Fatalf("%s:%d: want \"<file> | <func> | <what> | <count> | <reason>\" with a reason, got %q", allowFile, n, line)
		}
		count, err := strconv.Atoi(parts[3])
		if err != nil || count < 1 {
			t.Fatalf("%s:%d: bad count %q", allowFile, n, parts[3])
		}
		key := strings.Join(parts[:3], " | ")
		if _, dup := out[key]; dup {
			t.Fatalf("%s:%d: %s is listed twice", allowFile, n, key)
		}
		out[key] = allowEntry{count: count, line: n}
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	return out
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
