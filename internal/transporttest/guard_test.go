package transporttest

import (
	"bufio"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// LLMTRANSPORT-01 — a consumer decides by capability, never by transport
// identity. Only the adapters (spec §1) may name a transport.

// modulePath is the Go module of the repository (go.mod).
const modulePath = "watchtower"

// adapterDirs are the adapter packages, relative to the repository root;
// every package under them is an adapter too.
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

// transportNames are the string literals that name a transport.
var transportNames = map[string]bool{"claude": true, "codex": true, "ollama": true, "http": true}

// agentKindPath is the package whose Claude/Codex constants name a
// Workbench agent's transport.
const agentKindPath = modulePath + "/internal/agentkind"

const allowFile = "testdata/llmtransport_allow.txt"

// TestLLMTRANSPORT01_NoTransportNamesOutsideAdapters fails on a transport
// name check outside the adapters that the baseline does not list: a
// comparison or switch case against "claude"/"codex"/"ollama"/"http" or
// agentkind.Claude/Codex, or a type assertion to a concrete adapter type.
// BEHAVIOR LLMTRANSPORT-01 — see docs/inventory/llm-transport.md
func TestLLMTRANSPORT01_NoTransportNamesOutsideAdapters(t *testing.T) {
	root := repoRoot(t)
	hits := scanRepo(t, root)
	allow := readAllow(t)
	for _, key := range sortedKeys(hits) {
		n := hits[key]
		if allowed := allow[key].count; n > allowed {
			t.Errorf("%s: %d transport name check(s), baseline allows %d. Decide by a capability "+
				"(providers.Capabilities) or move the code into an adapter; a new baseline entry needs "+
				"the owner's approval (LLMTRANSPORT-01)", key, n, allowed)
		}
	}
}

// TestLLMTRANSPORT01_BaselineOnlyShrinks fails on a baseline entry that no
// longer matches (delete it or lower its count) and on one without a reason.
// BEHAVIOR LLMTRANSPORT-01 — see docs/inventory/llm-transport.md
func TestLLMTRANSPORT01_BaselineOnlyShrinks(t *testing.T) {
	root := repoRoot(t)
	hits := scanRepo(t, root)
	for key, e := range readAllow(t) {
		if strings.TrimSpace(e.reason) == "" {
			t.Errorf("%s (line %d) has no reason", key, e.line)
		}
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
	if k == agentkind.Codex {
		return 4
	}
	if _, ok := g.(*codex.Client); ok {
		return 5
	}
	switch g.(type) {
	case *codex.Client:
		return 6
	}
	if _, ok := g.(kind.ImageCapable); ok {
		return 7
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
	concrete := map[string]bool{modulePath + "/internal/codex.Client": true}
	got := map[string]int{}
	for _, h := range fileHits(f, "x/consumer.go", concrete, false) {
		got[h]++
	}
	want := map[string]int{
		`x/consumer.go | pick | "codex"`:              1,
		`x/consumer.go | pick | "ollama"`:             1,
		`x/consumer.go | pick | "claude"`:             1,
		`x/consumer.go | pick | "http"`:               1,
		`x/consumer.go | pick | agentkind.Codex`:      1,
		`x/consumer.go | pick | assert *codex.Client`: 2,
		`x/consumer.go | var routed | "claude"`:       1,
		`x/consumer.go | (*Server).other | "codex"`:   1,
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("hits:\n  %v\nwant:\n  %v", got, want)
	}
}

// scanRepo returns every name check outside the adapters, keyed
// "<file> | <func> | <what>", with its count.
func scanRepo(t *testing.T, root string) map[string]int {
	t.Helper()
	concrete := concreteAdapterTypes(t, root)
	fset := token.NewFileSet()
	hits := map[string]int{}
	for _, dir := range []string{"cmd", "internal"} {
		err := filepath.WalkDir(filepath.Join(root, dir), func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			rel, _ := filepath.Rel(root, path)
			rel = filepath.ToSlash(rel)
			if d.IsDir() {
				if d.Name() == "testdata" || isAdapterDir(rel) {
					return filepath.SkipDir
				}
				return nil
			}
			if !strings.HasSuffix(rel, ".go") || strings.HasSuffix(rel, "_test.go") || isAdapterFile(rel) {
				return nil
			}
			f, err := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
			if err != nil {
				return err
			}
			inAgentKind := filepath.ToSlash(filepath.Dir(rel)) == "internal/agentkind"
			for _, h := range fileHits(f, rel, concrete, inAgentKind) {
				hits[h]++
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	return hits
}

func isAdapterDir(rel string) bool {
	for _, d := range adapterDirs {
		if rel == d || strings.HasPrefix(rel, d+"/") {
			return true
		}
	}
	return false
}

func isAdapterFile(rel string) bool {
	for _, f := range adapterFiles {
		if rel == f {
			return true
		}
	}
	return false
}

// concreteAdapterTypes lists "<import path>.<Type>" for every non-interface
// type the adapter packages declare.
func concreteAdapterTypes(t *testing.T, root string) map[string]bool {
	t.Helper()
	out := map[string]bool{}
	fset := token.NewFileSet()
	for _, dir := range adapterDirs {
		abs := filepath.Join(root, dir)
		if _, err := os.Stat(abs); os.IsNotExist(err) {
			continue
		}
		err := filepath.WalkDir(abs, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				if d.Name() == "testdata" {
					return filepath.SkipDir
				}
				return nil
			}
			if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
				return nil
			}
			f, err := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
			if err != nil {
				return err
			}
			rel, _ := filepath.Rel(root, filepath.Dir(path))
			pkgPath := modulePath + "/" + filepath.ToSlash(rel)
			for _, decl := range f.Decls {
				gd, ok := decl.(*ast.GenDecl)
				if !ok || gd.Tok != token.TYPE {
					continue
				}
				for _, spec := range gd.Specs {
					ts := spec.(*ast.TypeSpec)
					if _, iface := ts.Type.(*ast.InterfaceType); !iface {
						out[pkgPath+"."+ts.Name.Name] = true
					}
				}
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	return out
}

// fileHits returns one key per name check in f. inAgentKind treats the bare
// Claude/Codex identifiers as the kinds (the agentkind package itself).
func fileHits(f *ast.File, rel string, concrete map[string]bool, inAgentKind bool) []string {
	imports := map[string]string{} // local name → import path
	for _, imp := range f.Imports {
		p, _ := strconv.Unquote(imp.Path.Value)
		name := p[strings.LastIndex(p, "/")+1:]
		if imp.Name != nil {
			name = imp.Name.Name
		}
		imports[name] = p
	}
	nameOf := func(e ast.Expr) string {
		switch x := e.(type) {
		case *ast.BasicLit:
			if x.Kind == token.STRING {
				if v, err := strconv.Unquote(x.Value); err == nil && transportNames[v] {
					return strconv.Quote(v)
				}
			}
		case *ast.SelectorExpr:
			if id, ok := x.X.(*ast.Ident); ok && imports[id.Name] == agentKindPath && (x.Sel.Name == "Claude" || x.Sel.Name == "Codex") {
				return "agentkind." + x.Sel.Name
			}
		case *ast.Ident:
			if inAgentKind && (x.Name == "Claude" || x.Name == "Codex") {
				return "agentkind." + x.Name
			}
		}
		return ""
	}
	assertOf := func(e ast.Expr) string {
		star := ""
		if s, ok := e.(*ast.StarExpr); ok {
			star, e = "*", s.X
		}
		sel, ok := e.(*ast.SelectorExpr)
		if !ok {
			return ""
		}
		id, ok := sel.X.(*ast.Ident)
		if !ok || !concrete[imports[id.Name]+"."+sel.Sel.Name] {
			return ""
		}
		p := imports[id.Name]
		return "assert " + star + p[strings.LastIndex(p, "/")+1:] + "." + sel.Sel.Name
	}

	var out []string
	visit := func(fn string, n ast.Node) {
		add := func(what string) {
			if what != "" {
				out = append(out, rel+" | "+fn+" | "+what)
			}
		}
		ast.Inspect(n, func(n ast.Node) bool {
			switch x := n.(type) {
			case *ast.BinaryExpr:
				if x.Op == token.EQL || x.Op == token.NEQ {
					if w := nameOf(x.X); w != "" {
						add(w)
					} else {
						add(nameOf(x.Y))
					}
				}
			case *ast.SwitchStmt:
				for _, c := range x.Body.List {
					for _, e := range c.(*ast.CaseClause).List {
						add(nameOf(e))
					}
				}
			case *ast.TypeAssertExpr:
				if x.Type != nil {
					add(assertOf(x.Type))
				}
			case *ast.TypeSwitchStmt:
				for _, c := range x.Body.List {
					for _, e := range c.(*ast.CaseClause).List {
						add(assertOf(e))
					}
				}
			}
			return true
		})
	}
	for _, decl := range f.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			visit(funcName(d), d)
		case *ast.GenDecl:
			for _, spec := range d.Specs {
				vs, ok := spec.(*ast.ValueSpec)
				if !ok {
					continue
				}
				var names []string
				for _, n := range vs.Names {
					names = append(names, n.Name)
				}
				visit("var "+strings.Join(names, ","), vs)
			}
		}
	}
	return out
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
	count  int
	reason string
	line   int
}

// readAllow parses the baseline: "<file> | <func> | <what> | <count> | <reason>"
// per line; blank lines and lines starting with # are skipped.
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
		if len(parts) != 5 {
			t.Fatalf("%s:%d: want \"<file> | <func> | <what> | <count> | <reason>\", got %q", allowFile, n, line)
		}
		count, err := strconv.Atoi(parts[3])
		if err != nil || count < 1 {
			t.Fatalf("%s:%d: bad count %q", allowFile, n, parts[3])
		}
		key := strings.Join(parts[:3], " | ")
		if _, dup := out[key]; dup {
			t.Fatalf("%s:%d: %s is listed twice", allowFile, n, key)
		}
		out[key] = allowEntry{count: count, reason: parts[4], line: n}
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

func sortedKeys(m map[string]int) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
