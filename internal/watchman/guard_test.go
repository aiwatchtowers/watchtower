package watchman

import (
	"context"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestWATCHMAN03_SourcesAreOwnerOnly pins WATCHMAN-03 ("twin decisions become
// precedents only after the owner's OK"): phase 1 learns from one closed list
// of sources, each reading only what the owner decided himself. A twin
// decision cannot become a precedent here because no source reads one; the
// phase-2 source of OK'd twin decisions joins this list under the same id.
func TestWATCHMAN03_SourcesAreOwnerOnly(t *testing.T) {
	all := append(DBSources(), TurnSource(nil), GitSource(nil))
	var names []string
	for _, s := range all {
		names = append(names, s.Name())
	}
	sort.Strings(names)
	require.Equal(t, []string{"ask", "git", "journal", "permission", "review", "spec", "turn"}, names,
		"the source list is closed: a new source needs the owner's approval (WATCHMAN-03)")

	// Rows nobody owner-made stand in the database next to one the owner
	// answered: the ask sources must return the owner's alone.
	d := openSourceDB(t)
	run := seedAutomationRun(t, d)
	keepAsk := seedAsk(t, d, askSeed{answeredAt: srcT0})
	seedAsk(t, d, askSeed{automationRun: run, answeredAt: srcT0})                 // an automation's ask
	seedAsk(t, d, askSeed{session: seedSession(t, d, 1, run), answeredAt: srcT0}) // a session an automation started
	seedAsk(t, d, askSeed{status: "open"})                                        // not answered
	seedAsk(t, d, askSeed{answer: `{"dismissed":true,"note":"not now"}`, answeredAt: srcT0})
	ps, _, _, err := (&asksSource{}).Next(context.Background(), d, 1, "", 50)
	require.NoError(t, err)
	require.Equal(t, []string{strconv.FormatInt(keepAsk, 10)}, keys(ps))

	s := seedSession(t, d, 1, nil)
	at := srcT0.Add(time.Hour)
	keepPerm := seedPermission(t, d, s, 1, "Edit", "a.go", "allowed", &at)
	seedPermission(t, d, s, 1, "Edit", "b.go", "pending", nil)
	seedPermission(t, d, s, 1, "Edit", "c.go", "expired", &at)
	seedPermission(t, d, s, 1, "Edit", "d.go", "answered_on_mac", &at)
	pp, _, _, err := (&permissionSource{}).Next(context.Background(), d, 1, "", 50)
	require.NoError(t, err)
	require.Equal(t, []string{strconv.FormatInt(keepPerm, 10)}, keys(pp))

	// What the twin decided never comes back as the owner's decision.
	twinAsk := seedAsk(t, d, askSeed{answeredAt: srcT0})
	twinSpec := seedSpecAsk(t, d, 1, "approved", srcT0)
	seedMark(t, d, twinSpec, "ag:1", "ok", "", "")
	twinPerm := seedPermission(t, d, s, 1, "Edit", "e.go", "allowed", &at)
	byTwin := seedPermission(t, d, s, 1, "Edit", "f.go", "allowed", &at)
	_, err = d.Exec(`UPDATE permission_requests SET decided_by = 'watchman' WHERE id = ?`, byTwin)
	require.NoError(t, err)
	twinRound := seedRound(t, d, 1, "sent", "approved", &at)
	twinComment := seedComment(t, d, twinRound, "a.go", "q", "twin note", "sent", nil)
	twinRevert := seedRevert(t, d, twinRound, "h1", at)
	ownerRound := seedRound(t, d, 1, "sent", "approved", &at)
	for _, it := range []db.WatchmanItem{
		{Kind: "ask", RefKind: "ask", RefID: twinAsk},
		{Kind: "review_doc", RefKind: "ask", RefID: twinSpec},
		{Kind: "permission", RefKind: "permission", RefID: twinPerm},
		{Kind: "review_code", RefKind: "round", RefID: twinRound},
	} {
		it.WorkbenchID = 1
		id, _, err := d.QueueWatchmanItem(it)
		require.NoError(t, err)
		_, err = d.Exec(`UPDATE watchman_items SET state = 'done', outcome = 'answered' WHERE id = ?`, id)
		require.NoError(t, err)
	}
	ps, _, _, err = (&asksSource{}).Next(context.Background(), d, 1, "", 50)
	require.NoError(t, err)
	require.NotContains(t, keys(ps), strconv.FormatInt(twinAsk, 10))
	require.NotContains(t, keys(ps), strconv.FormatInt(twinSpec, 10))
	require.Contains(t, keys(ps), strconv.FormatInt(keepAsk, 10))
	sp, _, _, err := (&specSource{}).Next(context.Background(), d, 1, "", 50)
	require.NoError(t, err)
	require.Empty(t, sp)
	pp, _, _, err = (&permissionSource{}).Next(context.Background(), d, 1, "", 50)
	require.NoError(t, err)
	require.Equal(t, []string{strconv.FormatInt(keepPerm, 10)}, keys(pp))
	rr, _, _, err := (&reviewSource{}).Next(context.Background(), d, 1, "", 50)
	require.NoError(t, err)
	got := keys(rr)
	require.NotContains(t, got, "round:"+strconv.FormatInt(twinRound, 10))
	require.NotContains(t, got, "comment:"+strconv.FormatInt(twinComment, 10))
	require.NotContains(t, got, "revert:"+strconv.FormatInt(twinRevert, 10))
	require.Contains(t, got, "round:"+strconv.FormatInt(ownerRound, 10))
}

// TestWATCHMAN06_NoActingImports pins WATCHMAN-06 ("learning and the backtest
// never act"): no non-test file of internal/watchman imports a package that
// can answer an ask, decide a permission, write a review or type into a
// session. Phase 2's acting code lives in its own package.
func TestWATCHMAN06_NoActingImports(t *testing.T) {
	forbidden := []string{"watchtower/internal/hub", "watchtower/internal/sessionhost", "watchtower/internal/tools"}
	files, err := filepath.Glob("*.go")
	require.NoError(t, err)
	require.NotEmpty(t, files)
	fset := token.NewFileSet()
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		src, err := os.ReadFile(f)
		require.NoError(t, err)
		parsed, err := parser.ParseFile(fset, f, src, parser.ImportsOnly)
		require.NoError(t, err)
		for _, imp := range parsed.Imports {
			path, err := strconv.Unquote(imp.Path.Value)
			require.NoError(t, err)
			for _, bad := range forbidden {
				require.Falsef(t, path == bad || strings.HasPrefix(path, bad+"/"),
					"%s imports %s: phase 1 never acts (WATCHMAN-06)", f, path)
			}
		}
	}
}
