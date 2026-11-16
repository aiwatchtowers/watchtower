package daemon

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/instructions"
	"watchtower/internal/sessionfeed"
)

type watchmanTestGen struct{ calls int }

func (g *watchmanTestGen) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	g.calls++
	return `["scope"]`, &digest.Usage{}, "", nil
}

// stubWatchman replaces the generator, git and the feed reader; it returns
// the generator and how many times the factory was asked for one.
func stubWatchman(t *testing.T) (*watchmanTestGen, *int) {
	t.Helper()
	gen, built := &watchmanTestGen{}, 0
	prevGen, prevGit, prevFeed := watchmanGeneratorFactory, watchmanGit, watchmanFeedReader
	watchmanGeneratorFactory = func(*config.Config) digest.Generator { built++; return gen }
	watchmanGit = func(context.Context, string, ...string) ([]byte, error) { return []byte("false\n"), nil }
	watchmanFeedReader = func(context.Context, *Daemon) instructions.FeedReader {
		return func(db.RecentWorkbenchSession) ([]sessionfeed.Entry, error) { return nil, nil }
	}
	t.Cleanup(func() { watchmanGeneratorFactory, watchmanGit, watchmanFeedReader = prevGen, prevGit, prevFeed })
	return gen, &built
}

func TestPhaseWatchmanLearn_SkipsWhenNoWorkbench(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	gen, built := stubWatchman(t)
	_, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)

	d.phaseWatchmanLearn(context.Background())
	assert.Empty(t, pipelineRunNames(t, database), "no Watchman workbench: no pipeline run")
	assert.Zero(t, *built)
	assert.Zero(t, gen.calls)
}

func TestPhaseWatchmanLearn_LearnsEnabledWorkbench(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	gen, _ := stubWatchman(t)
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	require.NoError(t, database.EnableWatchmanWorkbench(wb, time.Now(), 1))
	_, err = database.Exec(`INSERT INTO owner_asks (project_id, kind, title, payload, status, answer, answered_at)
		VALUES (?, 'question', 'Pick a cache',
			'{"focus":[],"questions":[{"id":"q1","question":"Which cache?","options":[{"label":"sqlite"},{"label":"redis"}]}],"checklist":[]}',
			'answered', '{"answers":[{"id":"q1","labels":["sqlite"],"other":""}],"checklist":[],"comments":[],"note":"","verdict":""}',
			'2026-11-01T09:00:00Z')`, wb)
	require.NoError(t, err)

	d.phaseWatchmanLearn(context.Background())
	assert.Equal(t, []string{"watchman-learn"}, pipelineRunNames(t, database))
	assert.Equal(t, 1, gen.calls)
	var category string
	require.NoError(t, database.QueryRow(`SELECT category FROM watchman_precedents WHERE workbench_id = ?`, wb).Scan(&category))
	assert.Equal(t, "scope", category)
	var learned *string
	require.NoError(t, database.QueryRow(`SELECT learned_through FROM watchman_workbenches WHERE workbench_id = ?`, wb).Scan(&learned))
	assert.NotNil(t, learned, "every source is done")
}
