package daemon

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Spec D5: the daemon never runs gh — a coach Applier it builds (or the
// judge builds for it) keeps the pull-request seams nil, and it never syncs
// pull requests. No file of the package names a seam or SyncPRs.
func TestCoachDaemon_NoPullRequestSeams(t *testing.T) {
	forbidden := map[string]bool{"RepoRoute": true, "RepoPublish": true, "RepoPRState": true, "RepoClosePR": true,
		"SyncPRs": true}
	files, err := filepath.Glob("*.go")
	require.NoError(t, err)
	scanned := 0
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		src, err := os.ReadFile(name)
		require.NoError(t, err)
		f, err := parser.ParseFile(token.NewFileSet(), name, src, 0)
		require.NoError(t, err)
		scanned++
		ast.Inspect(f, func(n ast.Node) bool {
			var id *ast.Ident
			switch x := n.(type) {
			case *ast.SelectorExpr:
				id = x.Sel
			case *ast.KeyValueExpr:
				id, _ = x.Key.(*ast.Ident)
			}
			if id != nil && forbidden[id.Name] {
				assert.Failf(t, "pull-request seam in the daemon", "%s names %s", name, id.Name)
			}
			return true
		})
	}
	assert.Positive(t, scanned)
}
