package watchman

import (
	"context"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestAsksSource_MapsRows(t *testing.T) {
	d := openSourceDB(t)
	q := seedAsk(t, d, askSeed{summary: "The importer re-reads every file.", answer: questionAnswer("sqlite", "no new dependency"), answeredAt: srcT0})
	r := seedAsk(t, d, askSeed{kind: "review", title: "Review the importer spec", docPath: "docs/specs/importer.md",
		docSnapshot: "# Importer\nRead once.", payload: `{"focus":[{"text":"the cache section"}],"questions":[],"checklist":[]}`,
		answer: `{"answers":[],"checklist":[],"comments":[{"body":"say how long entries live","heading":"Cache","prefix":"","quote":"Read once.","suffix":""}],"note":"close","verdict":"changes"}`,
		status: "delivered", answeredAt: srcT0.Add(time.Hour)})

	ps, _, done, err := asksSource{}.Next(context.Background(), d, 1, "", 10)
	require.NoError(t, err)
	require.True(t, done)
	require.Len(t, ps, 2)

	rv, qu := ps[0], ps[1]
	require.Equal(t, strconv.FormatInt(r, 10), rv.SourceKey)
	require.Equal(t, "ask", rv.Source)
	require.Equal(t, int64(1), rv.WorkbenchID)
	require.Equal(t, "review_doc", rv.Category)
	require.Equal(t, "changes", rv.Choice)
	require.Contains(t, rv.Situation, "Review of docs/specs/importer.md")
	require.Contains(t, rv.Situation, "Focus: the cache section")
	require.Contains(t, rv.Situation, "Read once.")
	require.Contains(t, rv.OwnerWords, "close")
	require.Contains(t, rv.OwnerWords, "> Read once.\nsay how long entries live")
	require.Equal(t, srcT0.Add(time.Hour), rv.DecidedAt)
	require.Equal(t, 1.0, rv.Weight)

	require.Equal(t, strconv.FormatInt(q, 10), qu.SourceKey)
	require.Equal(t, "", qu.Category, "questions are labelled by the runner")
	require.Equal(t, "sqlite", qu.Choice)
	require.Equal(t, "no new dependency", qu.OwnerWords)
	require.Contains(t, qu.Situation, "Pick a cache")
	require.Contains(t, qu.Situation, "Which cache should the importer use?")
	require.Contains(t, qu.Situation, "- sqlite (recommended)")
	require.Equal(t, srcT0, qu.DecidedAt)
}

func TestAsksSource_MapsCheckAsk(t *testing.T) {
	d := openSourceDB(t)
	seedAsk(t, d, askSeed{kind: "check", title: "Try the import",
		payload:    `{"focus":[],"questions":[],"checklist":[{"id":"c1","text":"run the import"},{"id":"c2","text":"open the report"}]}`,
		answer:     `{"answers":[],"checklist":[{"id":"c1","note":"","state":"ok"},{"id":"c2","note":"blank page","state":"broken"}],"comments":[],"note":"","verdict":""}`,
		answeredAt: srcT0})
	ps, _, _, err := asksSource{}.Next(context.Background(), d, 1, "", 10)
	require.NoError(t, err)
	require.Len(t, ps, 1)
	require.Equal(t, "", ps[0].Category)
	require.Equal(t, "broken: open the report", ps[0].Choice)
	require.Equal(t, "open the report: blank page", ps[0].OwnerWords)
	require.Contains(t, ps[0].Situation, "- run the import")
}

func TestAsksSource_CursorNewestFirst(t *testing.T) {
	d := openSourceDB(t)
	checkNewestFirst(t, d, asksSource{}, func(_ int, at time.Time) string {
		return strconv.FormatInt(seedAsk(t, d, askSeed{answeredAt: at}), 10)
	})
}

func TestAsksSource_SkipsAutomationAndOpen(t *testing.T) {
	d := openSourceDB(t)
	run := seedAutomationRun(t, d)
	keep := seedAsk(t, d, askSeed{answeredAt: srcT0})
	seedAsk(t, d, askSeed{automationRun: run, answeredAt: srcT0})                            // an automation's ask
	seedAsk(t, d, askSeed{session: seedSession(t, d, 1, run), answeredAt: srcT0})            // from a session an automation started
	seedAsk(t, d, askSeed{status: "open"})                                                   // not answered
	seedAsk(t, d, askSeed{status: "withdrawn"})                                              // never answered
	seedAsk(t, d, askSeed{wb: 2, answeredAt: srcT0})                                         // another workbench
	seedAsk(t, d, askSeed{answer: `{"dismissed":true,"note":"not now"}`, answeredAt: srcT0}) // dismissed: no decision
	chat := seedAsk(t, d, askSeed{session: seedSession(t, d, 1, nil), answeredAt: srcT0.Add(time.Minute)})
	_, err := d.Exec(`UPDATE owner_asks SET origin = 'chat' WHERE id = ?`, chat)
	require.NoError(t, err)

	ps, _, done, err := asksSource{}.Next(context.Background(), d, 1, "", 50)
	require.NoError(t, err)
	require.True(t, done)
	require.Equal(t, []string{strconv.FormatInt(chat, 10), strconv.FormatInt(keep, 10)}, keys(ps))
}

func TestAsksSource_RedactsSituation(t *testing.T) {
	d := openSourceDB(t)
	secret := "sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789" // leak-check:allow
	seedAsk(t, d, askSeed{summary: "The importer fails with token " + secret + "\n" + strings.Repeat("long context ", 400),
		answer: questionAnswer("sqlite", "use password="+secret), answeredAt: srcT0}) // leak-check:allow
	ps, _, _, err := asksSource{}.Next(context.Background(), d, 1, "", 10)
	require.NoError(t, err)
	require.Len(t, ps, 1)
	require.NotContains(t, ps[0].Situation, secret)
	require.Contains(t, ps[0].Situation, "[secret]")
	require.NotContains(t, ps[0].OwnerWords, secret)
	require.LessOrEqual(t, len([]rune(ps[0].Situation)), SituationLimit)
	require.True(t, strings.HasSuffix(ps[0].Situation, "…"))
}
