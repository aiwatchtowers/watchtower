package daemon

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/png"
	"io"
	"math/rand"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/media"
)

// mediaTestGen is a vision-capable generator; every call fails when fail.
type mediaTestGen struct {
	fail  bool
	calls atomic.Int32
}

func (g *mediaTestGen) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	g.calls.Add(1)
	if g.fail {
		return "", nil, "", errors.New("provider down")
	}
	return `{"title":"Page","summary":"The page describes something."}`, nil, "", nil
}

func (g *mediaTestGen) GenerateWithImage(context.Context, string, string, string, string) (string, *digest.Usage, error) {
	g.calls.Add(1)
	if g.fail {
		return "", nil, errors.New("provider down")
	}
	return `{"title":"Chart","description":"The image shows a chart.","text":"","keys":[]}`, &digest.Usage{InputTokens: 4, OutputTokens: 2}, nil
}

// mediaTestOpener serves one noise PNG for every item.
type mediaTestOpener struct{ opens atomic.Int32 }

func (o *mediaTestOpener) Open(context.Context, db.MediaItem, int64) (io.ReadCloser, string, error) {
	o.opens.Add(1)
	rng := rand.New(rand.NewSource(1))
	img := image.NewRGBA(image.Rect(0, 0, 64, 64))
	for i := range img.Pix {
		img.Pix[i] = byte(rng.Intn(256))
	}
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		return nil, "", err
	}
	return io.NopCloser(&b), "image/png", nil
}

// seedPendingMedia records one pending image and one pending link on a
// Slack message and returns their ids.
func seedPendingMedia(t *testing.T, database *db.DB) (imageID, linkID int64) {
	t.Helper()
	require.NoError(t, database.SetMediaStartAt(time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC)))
	_, err := database.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:CM', 'media', 'public')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:CM', '1758000000.000100', '1:U1', 'look')`)
	require.NoError(t, err)
	p := db.MediaParent{Kind: "slack", SlackChannelID: "1:CM", SlackTS: "1758000000.000100", ContentAt: time.Now()}
	_, err = db.RecordMedia(context.Background(), database, p, []db.MediaFound{
		{Kind: "image", Locator: "F1", MediaType: "image/png"},
		// A synced host: the fetcher's check refuses it before any DNS
		// lookup or socket, so no test touches the network.
		{Kind: "link", Locator: "url:https://linear.app/a", FetchURL: "https://linear.app/a", ContentKey: "url:https://linear.app/a"},
	})
	require.NoError(t, err)
	require.NoError(t, database.QueryRow(`SELECT id FROM media_items WHERE kind = 'image'`).Scan(&imageID))
	require.NoError(t, database.QueryRow(`SELECT id FROM media_items WHERE kind = 'link'`).Scan(&linkID))
	return imageID, linkID
}

func newMediaTestPipeline(d *Daemon, database *db.DB, gen digest.Generator, op media.Opener) {
	d.SetMediaPipeline(&media.Pipeline{
		DB: database, Gen: gen, WorkspaceDir: d.config.WorkspaceDir(),
		Openers: map[string]media.Opener{"slack": op}, Logger: d.logger,
	})
}

// assertMediaUntouched: the rows were never worked (no fetch, no open).
func assertMediaUntouched(t *testing.T, database *db.DB, ids ...int64) {
	t.Helper()
	for _, id := range ids {
		var status, describedAt string
		var attempts int
		require.NoError(t, database.QueryRow(`SELECT status, attempts, described_at FROM media_items WHERE id = ?`, id).
			Scan(&status, &attempts, &describedAt))
		assert.Equal(t, "pending", status)
		assert.Zero(t, attempts)
		assert.Empty(t, describedAt)
	}
}

func TestPhaseMediaDescribe_KnowledgeOffWritesNothing(t *testing.T) {
	d, database := newKnowledgeTestDaemon(t)
	d.config.Knowledge.Enabled = false
	img, link := seedPendingMedia(t, database)
	gen, op := &mediaTestGen{}, &mediaTestOpener{}
	newMediaTestPipeline(d, database, gen, op)

	d.phaseMediaDescribe(context.Background())

	assert.Zero(t, gen.calls.Load(), "no model call")
	assert.Zero(t, op.opens.Load(), "no download")
	assertMediaUntouched(t, database, img, link)
	assert.Zero(t, countPipelineRuns(t, database, "media-describe"))
}

func TestPhaseMediaDescribe_NearLimitSkips(t *testing.T) {
	d, database := newKnowledgeTestDaemon(t)
	d.config.Knowledge.Enabled = true
	img, link := seedPendingMedia(t, database)
	gen, op := &mediaTestGen{}, &mediaTestOpener{}
	newMediaTestPipeline(d, database, gen, op)
	setNearLimit(t, database, true)

	d.phaseMediaDescribe(context.Background())

	assert.Zero(t, gen.calls.Load())
	assert.Zero(t, op.opens.Load())
	assertMediaUntouched(t, database, img, link)
	assert.Zero(t, countPipelineRuns(t, database, "media-describe"))

	setNearLimit(t, database, false)
	d.phaseMediaDescribe(context.Background())
	assert.Equal(t, 1, countPipelineRuns(t, database, "media-describe"))
	var status string
	require.NoError(t, database.QueryRow(`SELECT status FROM media_items WHERE id = ?`, img).Scan(&status))
	assert.Equal(t, "ok", status, "the gate open, the image is described")
}

func TestPhaseMediaDescribe_ErrorDoesNotStopKnowledgeIndex(t *testing.T) {
	d, database := newKnowledgeTestDaemon(t)
	d.config.Knowledge.Enabled = true
	img, _ := seedPendingMedia(t, database)
	gen := &mediaTestGen{fail: true}
	newMediaTestPipeline(d, database, gen, &mediaTestOpener{})

	d.runSync(context.Background(), context.Background())

	assert.Positive(t, gen.calls.Load(), "the failing generator was called")
	var attempts int
	require.NoError(t, database.QueryRow(`SELECT attempts FROM media_items WHERE id = ?`, img).Scan(&attempts))
	assert.Equal(t, 1, attempts)
	assert.Equal(t, 1, countPipelineRuns(t, database, "media-describe"))
	assert.Equal(t, 1, countPipelineRuns(t, database, "knowledge-index"), "the index still runs this cycle")
	var errMsg string
	require.NoError(t, database.QueryRow(`SELECT COALESCE(error_msg, '') FROM pipeline_runs WHERE pipeline = 'media-describe'`).Scan(&errMsg))
	assert.Empty(t, errMsg, "media errors are logged only")
}

func TestPhaseMediaDescribe_IdleCycleWritesNoRun(t *testing.T) {
	d, database := newKnowledgeTestDaemon(t)
	d.config.Knowledge.Enabled = true
	gen := &mediaTestGen{}
	newMediaTestPipeline(d, database, gen, &mediaTestOpener{})

	d.phaseMediaDescribe(context.Background())

	assert.Zero(t, countPipelineRuns(t, database, "media-describe"), "nothing pending: no run row")
	assert.Zero(t, gen.calls.Load())
}

func TestPhaseMediaDescribe_RefusedLinkNeverFetched(t *testing.T) {
	d, database := newKnowledgeTestDaemon(t)
	d.config.Knowledge.Enabled = true
	_, link := seedPendingMedia(t, database)
	newMediaTestPipeline(d, database, &mediaTestGen{}, &mediaTestOpener{})

	d.phaseMediaDescribe(context.Background())

	var status, class string
	require.NoError(t, database.QueryRow(`SELECT status, error FROM media_items WHERE id = ?`, link).Scan(&status, &class))
	assert.Equal(t, "unreachable", status)
	assert.Equal(t, "refused", class)
}
