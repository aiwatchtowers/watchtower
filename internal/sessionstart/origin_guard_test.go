package sessionstart

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/aiconsent"
)

// TestBGAI01_RunSessionsCarryTheirOrigin (#1886 §4.3): every launch Mode
// built in this package that names an automation run also sets its
// OriginEnv, so a background run's session is admitted as its run and an
// owner-run's carries nothing; and Launch passes OriginEnv to an agent.
func TestBGAI01_RunSessionsCarryTheirOrigin(t *testing.T) {
	files, err := filepath.Glob("*.go")
	require.NoError(t, err)
	fset := token.NewFileSet()
	modes := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fset, f, nil, 0)
		require.NoError(t, err)
		ast.Inspect(file, func(n ast.Node) bool {
			lit, ok := n.(*ast.CompositeLit)
			if !ok {
				return true
			}
			if id, ok := lit.Type.(*ast.Ident); !ok || id.Name != "Mode" {
				return true
			}
			keys := map[string]bool{}
			for _, e := range lit.Elts {
				if kv, ok := e.(*ast.KeyValueExpr); ok {
					if k, ok := kv.Key.(*ast.Ident); ok {
						keys[k.Name] = true
					}
				}
			}
			if keys["AutomationRunID"] {
				modes++
				assert.True(t, keys["OriginEnv"], "%s: a Mode naming an automation run sets OriginEnv", fset.Position(lit.Pos()))
			}
			return true
		})
	}
	assert.Positive(t, modes, "the scan found no run launch: wrong package?")

	env := []string{aiconsent.EnvOrigin + "=background", aiconsent.EnvAdmitted + "=run:7"}
	spec, err := Launch(Mode{Agent: "claude", SessionID: "0b5e4f1c-8b8a-4c55-9a43-2f1d4c7b9e10", AutomationRunID: 7,
		OriginEnv: env}, 1, "/tmp", "/bin/zsh", nil, "")
	require.NoError(t, err)
	assert.Subset(t, spec.Env, env)
	shell, err := Launch(Mode{}, 1, "/tmp", "/bin/zsh", nil, "")
	require.NoError(t, err)
	assert.Empty(t, shell.Env, "a shell carries nothing")
}
