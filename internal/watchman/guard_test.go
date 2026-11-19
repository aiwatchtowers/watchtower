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
		id, _, err := queueItem(d, it)
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

	// Final review (codex 3): only what the twin wrote is left out. A park
	// or hand-back the owner answered later, an owner-first item and a
	// superseded one are his decisions; a park whose text the twin wrote
	// onto the ask is not.
	parkText := questionAnswer("", db.WatchmanParkedPrefix+"a release")
	handText := questionAnswer("", db.WatchmanHandedPrefix+"sign in to the store")
	twinParked := seedAsk(t, d, askSeed{answer: parkText, answeredAt: srcT0})
	twinHanded := seedAsk(t, d, askSeed{answer: handText, answeredAt: srcT0})
	ownerAfterPark := seedAsk(t, d, askSeed{answeredAt: srcT0})
	ownerAfterHand := seedAsk(t, d, askSeed{answeredAt: srcT0})
	ownerFirst := seedAsk(t, d, askSeed{answeredAt: srcT0})
	superseded := seedAsk(t, d, askSeed{answeredAt: srcT0})
	ownerSpecAfterPark := seedSpecAsk(t, d, 1, "approved", srcT0)
	seedMark(t, d, ownerSpecAfterPark, "ag:1", "ok", "", "")
	ownerPermFirst := seedPermission(t, d, s, 1, "Edit", "g.go", "allowed", &at)
	parkedRound := seedRound(t, d, 1, "sent", "changes", &at)
	ownerFirstRound := seedRound(t, d, 1, "sent", "approved", &at)
	for _, c := range []struct {
		kind, refKind string
		refID         int64
		outcome       string
	}{
		{"ask", "ask", twinParked, "parked"},
		{"ask", "ask", twinHanded, "handed"},
		{"review_doc", "ask", ownerAfterPark, "parked"},
		{"review_doc", "ask", ownerAfterHand, "handed"},
		{"ask", "ask", ownerFirst, "owner_first"},
		{"ask", "ask", superseded, "superseded"},
		{"review_doc", "ask", ownerSpecAfterPark, "parked"},
		{"permission", "permission", ownerPermFirst, "owner_first"},
		{"review_code", "round", parkedRound, "parked"},
		{"review_code", "round", ownerFirstRound, "owner_first"},
	} {
		_, err := d.Exec(`INSERT INTO watchman_items (workbench_id, kind, ref_kind, ref_id, state, outcome, created_at)
			VALUES (1, ?, ?, ?, 'done', ?, '2026-11-18T01:00:00.000Z')`, c.kind, c.refKind, c.refID, c.outcome)
		require.NoError(t, err)
	}
	ps, _, _, err = (&asksSource{}).Next(context.Background(), d, 1, "", 100)
	require.NoError(t, err)
	got = keys(ps)
	require.NotContains(t, got, strconv.FormatInt(twinParked, 10), "the twin's park text is not the owner's answer")
	require.NotContains(t, got, strconv.FormatInt(twinHanded, 10), "nor its hand-back text")
	for _, id := range []int64{ownerAfterPark, ownerAfterHand, ownerFirst, superseded} {
		require.Contains(t, got, strconv.FormatInt(id, 10), "the owner's own answer")
	}
	sp, _, _, err = (&specSource{}).Next(context.Background(), d, 1, "", 100)
	require.NoError(t, err)
	require.NotEmpty(t, sp, "the owner's spec verdict after a park")
	pp, _, _, err = (&permissionSource{}).Next(context.Background(), d, 1, "", 100)
	require.NoError(t, err)
	require.Contains(t, keys(pp), strconv.FormatInt(ownerPermFirst, 10))
	rr, _, _, err = (&reviewSource{}).Next(context.Background(), d, 1, "", 100)
	require.NoError(t, err)
	got = keys(rr)
	require.Contains(t, got, "round:"+strconv.FormatInt(parkedRound, 10), "the owner's round after the twin parked")
	require.Contains(t, got, "round:"+strconv.FormatInt(ownerFirstRound, 10))
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
