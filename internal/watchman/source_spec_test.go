package watchman

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

const specResult = `{"summary":"","brief":"","theses":[],"agreements":[{"key":"ag:1","text":"Entries expire after a day","status":"missing","note":"the spec never says","chapter":"ch:1","source":{"kind":"ask","ref":"ask:1","quote":"a day","speaker":"owner"},"where":null}],"decided_alone":[],"blind_spots":[{"key":"bs:1","text":"No limit on cache size","why":"memory grows","chapter":"ch:1","where":null,"evidence":null}],"checks":[],"resolved":[],"chapters":[],"notes":[],"code_read":false,"dropped":0}`

func seedSpecAsk(t *testing.T, d *db.DB, wb int64, verdict string, at time.Time) int64 {
	t.Helper()
	id := seedAsk(t, d, askSeed{wb: wb, kind: "review", title: "Review the importer spec", docPath: "docs/specs/importer.md",
		docSnapshot: "# Importer", payload: `{"focus":[],"questions":[],"checklist":[]}`,
		answer: fmt.Sprintf(`{"answers":[],"checklist":[],"comments":[],"note":"","verdict":%q}`, verdict), answeredAt: at})
	_, err := d.Exec(`INSERT INTO spec_reviews (ask_id, status, result, queued_at) VALUES (?, 'done', ?, ?)`, id, specResult, stamp(at))
	require.NoError(t, err)
	return id
}

func seedMark(t *testing.T, d *db.DB, ask int64, key, state, body, about string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO spec_review_marks (ask_id, item_key, state, body, about, updated_at) VALUES (?, ?, ?, ?, ?, ?)`,
		ask, key, state, body, about, stamp(srcT0))
	require.NoError(t, err)
}

func TestSpecSource_MapsRows(t *testing.T) {
	d := openSourceDB(t)
	a := seedSpecAsk(t, d, 1, "changes", srcT0)
	seedMark(t, d, a, "ag:1", "comment", "say a day in the cache section", "")
	seedMark(t, d, a, "bs:1", "not_useful", "", "")
	seedMark(t, d, a, "ag:gone", "ok", "", "Dropped finding text")
	seedMark(t, d, a, "ch:1", "viewed", "", "") // viewed is no decision
	open := seedAsk(t, d, askSeed{kind: "review", docPath: "docs/specs/x.md", payload: `{"focus":[],"questions":[],"checklist":[]}`, status: "open"})
	seedMark(t, d, open, "ag:1", "ok", "", "") // the ask is not answered yet
	other := seedSpecAsk(t, d, 2, "approved", srcT0)
	seedMark(t, d, other, "ag:1", "ok", "", "")

	ps, _, done, err := (&specSource{}).Next(context.Background(), d, 1, "", 20)
	require.NoError(t, err)
	require.True(t, done)
	got := byKey(ps)
	require.Len(t, got, 3, "%v", keys(ps))

	c := got[fmt.Sprintf("%d:ag:1", a)]
	require.Equal(t, "spec", c.Source)
	require.Equal(t, "review_doc", c.Category)
	require.Equal(t, "comment", c.Choice)
	require.Equal(t, "say a day in the cache section\nVerdict: changes", c.OwnerWords)
	require.Contains(t, c.Situation, "Spec review of docs/specs/importer.md")
	require.Contains(t, c.Situation, "Finding: Entries expire after a day — missing — the spec never says")
	require.Equal(t, srcT0, c.DecidedAt)

	n := got[fmt.Sprintf("%d:bs:1", a)]
	require.Equal(t, "finding not useful", n.Choice)
	require.Contains(t, n.Situation, "Finding: No limit on cache size — memory grows")

	g := got[fmt.Sprintf("%d:ag:gone", a)]
	require.Equal(t, "ok", g.Choice)
	require.Contains(t, g.Situation, "Finding: Dropped finding text")
}

func TestSpecSource_CursorNewestFirst(t *testing.T) {
	d := openSourceDB(t)
	checkNewestFirst(t, d, &specSource{}, func(_ int, at time.Time) string {
		a := seedSpecAsk(t, d, 1, "approved", at)
		seedMark(t, d, a, "ag:1", "ok", "", "")
		return fmt.Sprintf("%d:ag:1", a)
	})
}

// Every mark of an ask shares its answered_at: a page boundary inside that
// tie neither repeats nor drops a mark.
func TestSpecSource_DrainsSameTimestampMarks(t *testing.T) {
	d := openSourceDB(t)
	a := seedSpecAsk(t, d, 1, "changes", srcT0)
	want := map[string]bool{}
	for _, k := range []string{"ag:1", "ag:2", "ag,3|x", "bs:1", "bs:2"} {
		seedMark(t, d, a, k, "ok", "", "")
		want[fmt.Sprintf("%d:%s", a, k)] = true
	}
	seen := map[string]bool{}
	cur := ""
	for i := 0; i < 5; i++ {
		ps, next, done, err := (&specSource{}).Next(context.Background(), d, 1, cur, 2)
		require.NoError(t, err)
		for _, k := range keys(ps) {
			require.False(t, seen[k], "repeated %s", k)
			seen[k] = true
		}
		cur = next
		if done {
			break
		}
	}
	require.Equal(t, want, seen)
}

func TestSpecSource_BadAnswerCounted(t *testing.T) {
	d := openSourceDB(t)
	logs := captureLog(t)
	bad := seedSpecAsk(t, d, 1, "changes", srcT0)
	seedMark(t, d, bad, "ag:1", "ok", "", "")
	_, err := d.Exec(`UPDATE owner_asks SET answer = '{"verdict":"Acme codename' WHERE id = ?`, bad)
	require.NoError(t, err)
	noResult := seedSpecAsk(t, d, 1, "approved", srcT0.Add(time.Hour))
	seedMark(t, d, noResult, "ag:1", "ok", "", "Kept about text")
	_, err = d.Exec(`UPDATE spec_reviews SET result = 'Acme codename' WHERE ask_id = ?`, noResult)
	require.NoError(t, err)

	src := &specSource{}
	ps, _, _, err := src.Next(context.Background(), d, 1, "", 10)
	require.NoError(t, err)
	require.Equal(t, []string{fmt.Sprintf("%d:ag:1", noResult)}, keys(ps), "a mark of an unreadable answer is skipped")
	require.Contains(t, ps[0].Situation, "Finding: Kept about text", "an unreadable result falls back to about")
	require.Equal(t, 2, src.Skipped())
	require.Contains(t, logs.String(), fmt.Sprintf("watchman: spec mark of ask %d skipped", bad))
	require.Contains(t, logs.String(), fmt.Sprintf("watchman: spec finding text of ask %d skipped", noResult))
	require.NotContains(t, logs.String(), "codename")
}
