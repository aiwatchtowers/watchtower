package cmd

import (
	"bytes"
	"go/ast"
	"log"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestRouteStdLog_RedirectsAndRestores pins the daemon's catch-all: while
// routed, a package-level log.Printf (internal/db, internal/ai, …) lands in the
// daemon's stream exactly once, and the restore puts the previous destination
// back so nothing outlives the daemon run.
func TestRouteStdLog_RedirectsAndRestores(t *testing.T) {
	var before, daemonStream bytes.Buffer
	prevOut := log.Writer()
	log.SetOutput(&before)
	t.Cleanup(func() { log.SetOutput(prevOut) })

	restore := routeStdLog(log.New(&daemonStream, "", 0))
	log.Print("from a daemon phase")
	restore()
	log.Print("after the daemon")

	assert.Equal(t, 1, strings.Count(daemonStream.String(), "from a daemon phase"))
	assert.NotContains(t, daemonStream.String(), "after the daemon")
	assert.NotContains(t, before.String(), "from a daemon phase")
	assert.Contains(t, before.String(), "after the daemon")
}

func TestSubLogger_KeepsPrefixOnParentStream(t *testing.T) {
	var buf bytes.Buffer
	sub := subLogger(log.New(&buf, "", 0), "[jira-analyzer] ")
	sub.Print("board 7 unchanged")
	assert.Equal(t, "[jira-analyzer] board 7 unchanged\n", buf.String())
}

// TestSyncWiring_EveryJiraComponentGetsTheDaemonLogger is a property scan over
// cmd/sync.go, the daemon's wiring file: every internal/jira type that exposes
// SetLogger defaults to os.Stderr — daemon.log for a detached child, which
// cannot be rotated while the daemon runs — so every construction of one there
// must be followed by SetLogger in the same function. The constructor set is
// discovered from internal/jira by return type, so a newly added component
// with a SetLogger seam is covered without editing this test.
//
// The scope is cmd/sync.go on purpose: it is where the daemon's long-lived
// components are built. cmd/actions_registry.go also constructs a Jira client
// and analyzer, but only inside External tools' Execute, which the daemon
// never runs (AGENT-03) — widen the scan if that ever changes.
//
// KeyDetector is the one exception to the per-function rule: it has a
// nil-returning gate constructor, so cmd/ wraps it once in newJiraKeyDetector
// and the scan instead requires every other function to go through that
// wrapper.
func TestSyncWiring_EveryJiraComponentGetsTheDaemonLogger(t *testing.T) {
	root := repoRootForPromptScan(t)
	jiraFiles := parseGoFilesUnder(t, root, filepath.Join(root, "internal", "jira"))
	ctors := jiraSetLoggerConstructors(jiraFiles)
	for _, want := range []string{"NewClient", "NewUserMapper", "NewBoardAnalyzer", "NewSyncer", "NewKeyDetector", "NewKeyDetectorIfEnabled"} {
		require.Truef(t, ctors[want], "discovery missed jira.%s (found %v) — the scan is probably broken", want, sortedKeys(ctors))
	}

	var syncFile *parsedGoFile
	for _, f := range parseGoFilesUnder(t, root, filepath.Join(root, "cmd")) {
		if filepath.Base(f.relPath) == "sync.go" {
			syncFile = &f
			break
		}
	}
	require.NotNil(t, syncFile, "cmd/sync.go not found")

	constructions := 0
	for _, decl := range syncFile.file.Decls {
		fd, ok := decl.(*ast.FuncDecl)
		if !ok || fd.Body == nil {
			continue
		}
		bound, unbound := jiraConstructionsIn(fd.Body, ctors)
		setters := setLoggerReceiversIn(fd.Body)
		for _, u := range unbound {
			t.Errorf("%s: jira.%s result is not bound to a variable — bind it so SetLogger can be proven", fd.Name.Name, u)
		}
		for name, ctor := range bound {
			constructions++
			if strings.HasPrefix(ctor, "NewKeyDetector") {
				if fd.Name.Name != "newJiraKeyDetector" {
					t.Errorf("%s: construct the key detector via newJiraKeyDetector, not jira.%s", fd.Name.Name, ctor)
				}
			}
			if !setters[name] {
				t.Errorf("%s: %s := jira.%s(…) is never given the daemon logger (%s.SetLogger)", fd.Name.Name, name, ctor, name)
			}
		}
	}
	// Coverage floor: client, mapper, syncer, analyzer in wireJiraSyncers plus
	// the detector in newJiraKeyDetector.
	require.GreaterOrEqual(t, constructions, 5, "found too few jira constructions in cmd/sync.go — the scan is probably broken")
}

// jiraSetLoggerConstructors returns the names of internal/jira's exported
// functions that return a pointer to a type with a SetLogger method.
func jiraSetLoggerConstructors(files []parsedGoFile) map[string]bool {
	types := map[string]bool{}
	for _, f := range files {
		for _, decl := range f.file.Decls {
			fd, ok := decl.(*ast.FuncDecl)
			if !ok || fd.Name.Name != "SetLogger" || fd.Recv == nil || len(fd.Recv.List) == 0 {
				continue
			}
			if name, ok := receiverTypeName(fd.Recv.List[0].Type); ok {
				types[name] = true
			}
		}
	}
	ctors := map[string]bool{}
	for _, f := range files {
		for _, decl := range f.file.Decls {
			fd, ok := decl.(*ast.FuncDecl)
			if ok && fd.Recv == nil && fd.Type.Results != nil && ast.IsExported(fd.Name.Name) && constructorReturnsAny(fd, types) {
				ctors[fd.Name.Name] = true
			}
		}
	}
	return ctors
}

// jiraConstructionsIn returns, for body, every `x := jira.Ctor(…)` binding
// (variable → constructor) plus the constructors called without a plain
// identifier binding.
func jiraConstructionsIn(body *ast.BlockStmt, ctors map[string]bool) (map[string]string, []string) {
	bound := map[string]string{}
	var unbound []string
	boundCalls := map[*ast.CallExpr]bool{}
	ast.Inspect(body, func(n ast.Node) bool {
		as, ok := n.(*ast.AssignStmt)
		if !ok || len(as.Rhs) != 1 {
			return true
		}
		call, ctor := jiraCtorCall(as.Rhs[0], ctors)
		if call == nil {
			return true
		}
		if id, ok := as.Lhs[0].(*ast.Ident); ok && id.Name != "_" {
			bound[id.Name] = ctor
			boundCalls[call] = true
		}
		return true
	})
	ast.Inspect(body, func(n ast.Node) bool {
		if call, ctor := jiraCtorCall(n, ctors); call != nil && !boundCalls[call] {
			unbound = append(unbound, ctor)
		}
		return true
	})
	return bound, unbound
}

func jiraCtorCall(n ast.Node, ctors map[string]bool) (*ast.CallExpr, string) {
	call, ok := n.(*ast.CallExpr)
	if !ok {
		return nil, ""
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return nil, ""
	}
	pkg, ok := sel.X.(*ast.Ident)
	if !ok || pkg.Name != "jira" || !ctors[sel.Sel.Name] {
		return nil, ""
	}
	return call, sel.Sel.Name
}

// setLoggerReceiversIn returns the identifiers x with an `x.SetLogger(…)` call
// in body.
func setLoggerReceiversIn(body *ast.BlockStmt) map[string]bool {
	out := map[string]bool{}
	ast.Inspect(body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || sel.Sel.Name != "SetLogger" {
			return true
		}
		if id, ok := sel.X.(*ast.Ident); ok {
			out[id.Name] = true
		}
		return true
	})
	return out
}
