package watchman

import (
	"go/ast"
	"go/parser"
	"go/token"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMode is the WATCHMAN-04 mode half (phase 2, D47): arming alone decides
// the mode; the acting half is the twin worker's (Task 9).
func TestMode(t *testing.T) {
	armedAt := time.Date(2026, 11, 18, 23, 40, 0, 0, time.UTC)
	nights := []time.Time{
		time.Date(2026, 11, 18, 23, 45, 0, 0, time.UTC), // inside a usual sleep window
		time.Date(2026, 11, 19, 14, 0, 0, 0, time.UTC),  // the middle of the day
	}
	for _, now := range nights {
		mode, since := Mode(now, ModeInputs{Armed: true, ArmedAt: armedAt})
		assert.Equal(t, ModeSleep, mode, now)
		assert.True(t, since.Equal(armedAt), now)

		mode, since = Mode(now, ModeInputs{ArmedAt: armedAt})
		assert.Equal(t, ModeOff, mode, now)
		assert.True(t, since.IsZero(), now)
	}
}

// TestMode_ReadsNothingElse: in phase 2 nothing but the arming changes the
// mode — mode.go imports only time and its code names no presence, away or
// sleep-window identifier (comments may).
func TestMode_ReadsNothingElse(t *testing.T) {
	f, err := parser.ParseFile(token.NewFileSet(), "mode.go", nil, 0)
	require.NoError(t, err)
	for _, imp := range f.Imports {
		path, err := strconv.Unquote(imp.Path.Value)
		require.NoError(t, err)
		assert.Equal(t, "time", path)
	}
	ast.Inspect(f, func(n ast.Node) bool {
		id, ok := n.(*ast.Ident)
		if !ok || id.Name == "ModeAway" {
			return true
		}
		name := strings.ToLower(id.Name)
		for _, banned := range []string{"platform", "presence", "away", "sleepwindow", "sleepspan", "window", "db"} {
			assert.NotContains(t, name, banned, "mode.go names %s", id.Name)
		}
		return true
	})
}
