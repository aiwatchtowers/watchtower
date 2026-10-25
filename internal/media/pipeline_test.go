package media

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"io"
	"log"
	"math/rand"
	"mime"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/kb"
	"watchtower/internal/media/linkrule"
	"watchtower/internal/media/webfetch"
)

// --- fixtures ---------------------------------------------------------------

// pipeGen is a vision-capable generator: GenerateWithImage runs describe
// (default: a fixed description), Generate answers a link summary.
type pipeGen struct {
	mu          sync.Mutex
	imageCalls  int
	textCalls   int
	describe    func(ctx context.Context, path, mediaType string) (string, error)
	mediaTypes  []string
	afterCall   func()
	summaryJSON string
}

func (g *pipeGen) GenerateWithImage(ctx context.Context, _, _, path, mediaType string) (string, *digest.Usage, error) {
	g.mu.Lock()
	g.imageCalls++
	g.mediaTypes = append(g.mediaTypes, mediaType)
	describe, after := g.describe, g.afterCall
	g.mu.Unlock()
	if after != nil {
		defer after()
	}
	if describe != nil {
		out, err := describe(ctx, path, mediaType)
		return out, &digest.Usage{InputTokens: 10, OutputTokens: 5}, err
	}
	return `{"title":"Chart","description":"The image shows a bar chart.","text":"Q3 PROJ-7","keys":["PROJ-7"]}`,
		&digest.Usage{InputTokens: 10, OutputTokens: 5}, nil
}

func (g *pipeGen) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	g.textCalls++
	out := g.summaryJSON
	g.mu.Unlock()
	if out == "" {
		out = `{"title":"Example page","summary":"The page describes the example."}`
	}
	return out, &digest.Usage{InputTokens: 7, OutputTokens: 3}, "", nil
}

func (g *pipeGen) calls() (img, text int) {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.imageCalls, g.textCalls
}

// textOnlyGen takes no images.
type textOnlyGen struct{ g *pipeGen }

func (t textOnlyGen) Generate(ctx context.Context, s, u, id string) (string, *digest.Usage, string, error) {
	return t.g.Generate(ctx, s, u, id)
}

// fakeOpener serves bytes per locator.
type fakeOpener struct {
	mu    sync.Mutex
	data  map[string][]byte
	errs  map[string]error
	read  map[string]func() io.Reader
	opens int
}

func (o *fakeOpener) Open(_ context.Context, it db.MediaItem, _ int64) (io.ReadCloser, string, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.opens++
	if err := o.errs[it.Locator]; err != nil {
		return nil, "", err
	}
	if r := o.read[it.Locator]; r != nil {
		return io.NopCloser(r()), it.MediaType, nil
	}
	return io.NopCloser(bytes.NewReader(o.data[it.Locator])), it.MediaType, nil
}

func (o *fakeOpener) count() int {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.opens
}

type env struct {
	t   *testing.T
	d   *db.DB
	ws  string
	p   *Pipeline
	gen *pipeGen
	op  *fakeOpener
	log *bytes.Buffer
}

func newEnv(t *testing.T) *env {
	t.Helper()
	d := db.OpenTestDB(t)
	require.NoError(t, d.SetMediaStartAt(time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC)))
	for _, ch := range []string{"1:C1", "2:C1"} {
		_, err := d.Exec(`INSERT INTO channels (id, name, type) VALUES (?, 'general', 'public')`, ch)
		require.NoError(t, err)
	}
	gen := &pipeGen{}
	op := &fakeOpener{data: map[string][]byte{}, errs: map[string]error{}, read: map[string]func() io.Reader{}}
	ws := t.TempDir()
	buf := &bytes.Buffer{}
	p := &Pipeline{DB: d, Gen: gen, WorkspaceDir: ws, Openers: map[string]Opener{"slack": op},
		Logger: log.New(buf, "", 0)}
	return &env{t: t, d: d, ws: ws, p: p, gen: gen, op: op, log: buf}
}

func (e *env) exec(q string, args ...any) {
	e.t.Helper()
	_, err := e.d.Exec(q, args...)
	require.NoError(e.t, err, q)
}

// msg inserts a Slack message (threadTS "" = top level, no thread).
func (e *env) msg(ch, ts, threadTS string) {
	e.t.Helper()
	var th any
	if threadTS != "" {
		th = threadTS
	}
	e.exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts, permalink) VALUES (?,?,?,?,?,?)`,
		ch, ts, "1:U1", "message "+ts, th, "https://slack.test/"+ts)
}

// add records one item on a fresh Slack message and returns its id.
func (e *env) add(ch, ts string, f db.MediaFound, owner bool) int64 {
	e.t.Helper()
	e.msg(ch, ts, "")
	return e.record(ch, ts, f, owner)
}

func (e *env) record(ch, ts string, f db.MediaFound, owner bool) int64 {
	e.t.Helper()
	p := db.MediaParent{Kind: "slack", SlackChannelID: ch, SlackTS: ts, ContentAt: time.Now(), FromOwner: owner}
	_, err := db.RecordMedia(context.Background(), e.d, p, []db.MediaFound{f})
	require.NoError(e.t, err)
	var id int64
	require.NoError(e.t, e.d.QueryRow(`SELECT id FROM media_items WHERE parent_key = ? AND kind = ? AND locator = ?`,
		p.Key(), f.Kind, f.Locator).Scan(&id))
	return id
}

func (e *env) image(ch, ts, locator string, data []byte) int64 {
	e.t.Helper()
	e.op.data[locator] = data
	return e.add(ch, ts, db.MediaFound{Kind: "image", Locator: locator, MediaType: "image/png"}, false)
}

func (e *env) link(ch, ts, raw string) int64 {
	e.t.Helper()
	norm, ok := linkrule.NormalizeURL(raw)
	require.True(e.t, ok)
	return e.add(ch, ts, db.MediaFound{Kind: "link", Locator: "url:" + norm, FetchURL: raw, ContentKey: "url:" + norm}, false)
}

func (e *env) run() Stats {
	e.t.Helper()
	st, err := e.p.Run(context.Background(), time.Minute)
	require.NoError(e.t, err)
	return st
}

type rowView struct {
	Kind, Status, Error, Title, Body, ImageText, ContentKey, KBSource, KBRef string
	Attempts                                                                 int
}

func (e *env) row(id int64) rowView {
	e.t.Helper()
	var r rowView
	require.NoError(e.t, e.d.QueryRow(`SELECT kind, status, error, title, body, image_text, content_key, kb_source, kb_ref, attempts
		FROM media_items WHERE id = ?`, id).Scan(&r.Kind, &r.Status, &r.Error, &r.Title, &r.Body, &r.ImageText,
		&r.ContentKey, &r.KBSource, &r.KBRef, &r.Attempts))
	return r
}

func (e *env) tempEntries() []string {
	e.t.Helper()
	entries, err := os.ReadDir(tempDir(e.ws))
	require.NoError(e.t, err)
	var names []string
	for _, x := range entries {
		names = append(names, x.Name())
	}
	return names
}

// noisePNG is a w×h PNG of random pixels (well over 2 KiB from 32×32 up).
func noisePNG(t *testing.T, w, h int, seed int64) []byte {
	t.Helper()
	rng := rand.New(rand.NewSource(seed))
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for i := range img.Pix {
		img.Pix[i] = byte(rng.Intn(256))
	}
	var b bytes.Buffer
	require.NoError(t, png.Encode(&b, img))
	return b.Bytes()
}

func solidPNG(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for i := 0; i < w; i++ {
		for j := 0; j < h; j++ {
			img.Set(i, j, color.RGBA{200, 10, 10, 255})
		}
	}
	var b bytes.Buffer
	require.NoError(t, png.Encode(&b, img))
	return b.Bytes()
}

func noiseJPEG(t *testing.T, w, h int) []byte {
	t.Helper()
	rng := rand.New(rand.NewSource(9))
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for i := range img.Pix {
		img.Pix[i] = byte(rng.Intn(256))
	}
	var b bytes.Buffer
	require.NoError(t, jpeg.Encode(&b, img, &jpeg.Options{Quality: 95}))
	return b.Bytes()
}

// stubSips points sipsPath at a script that copies out (a JPEG) to the
// --out path and logs its args; returns the log path.
func stubSips(t *testing.T, out []byte) string {
	t.Helper()
	dir := t.TempDir()
	fixture := filepath.Join(dir, "out.jpg")
	require.NoError(t, os.WriteFile(fixture, out, 0o600))
	logPath := filepath.Join(dir, "calls.log")
	script := filepath.Join(dir, "sips")
	body := "#!/bin/sh\necho \"$*\" >> '" + logPath + "'\nfor a; do last=$a; done\ncp '" + fixture + "' \"$last\"\n"
	require.NoError(t, os.WriteFile(script, []byte(body), 0o700))
	prev := sipsPath
	sipsPath = script
	t.Cleanup(func() { sipsPath = prev })
	return logPath
}

func readLog(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return ""
	}
	require.NoError(t, err)
	return string(b)
}

// testWeb is the run's web fetcher in tests: real HTTP to httptest servers
// named by host (any port), with the pass's check run on the first URL and
// on every redirect hop, as webfetch.Fetcher does.
type testWeb struct {
	check   func(string) bool
	hosts   map[string]*httptest.Server
	timeout time.Duration
	gets    *[]string // "<timeout> <url>" per Get
	mu      *sync.Mutex
}

func (w *testWeb) Get(ctx context.Context, raw string, maxBytes int64) (*webfetch.Response, error) {
	w.mu.Lock()
	*w.gets = append(*w.gets, w.timeout.String()+" "+raw)
	w.mu.Unlock()
	if !w.check(raw) {
		return nil, webfetch.ErrRefused
	}
	tr := &http.Transport{DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
		host, _, _ := net.SplitHostPort(addr)
		srv := w.hosts[host]
		if srv == nil {
			return nil, fmt.Errorf("no test server for %s", host)
		}
		return (&net.Dialer{}).DialContext(ctx, network, srv.Listener.Addr().String())
	}}
	client := &http.Client{Transport: tr, CheckRedirect: func(req *http.Request, _ []*http.Request) error {
		if !w.check(req.URL.String()) {
			return webfetch.ErrRefused
		}
		return nil
	}}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, raw, nil)
	if err != nil {
		return nil, webfetch.ErrRefused
	}
	resp, err := client.Do(req)
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		_ = resp.Body.Close()
		return nil, webfetch.ErrNotFound
	}
	mt, _, _ := mime.ParseMediaType(resp.Header.Get("Content-Type"))
	return &webfetch.Response{FinalURL: resp.Request.URL.String(), MediaType: mt, Body: resp.Body}, nil
}

// web serves the run's fetches from hosts and returns the log of Gets.
func (e *env) web(hosts map[string]*httptest.Server) func() []string {
	var gets []string
	var mu sync.Mutex
	e.p.newWeb = func(check func(string) bool, timeout time.Duration) webGetter {
		return &testWeb{check: check, hosts: hosts, timeout: timeout, gets: &gets, mu: &mu}
	}
	return func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), gets...)
	}
}

func page(text string) string {
	return "<html><head><title>Example page</title></head><body><p>" + text + "</p></body></html>"
}

var longText = strings.Repeat("The example page explains how the example domain is used in documents. ", 6)

// --- the pass ---------------------------------------------------------------

func TestPipeline_DescribesImageAndCopiesDuplicate(t *testing.T) {
	e := newEnv(t)
	img := noisePNG(t, 64, 64, 1)
	a := e.image("1:C1", "1758000000.000100", "F1", img)
	b := e.image("1:C1", "1758090000.000200", "F2", img)

	st := e.run()

	imgCalls, _ := e.gen.calls()
	assert.Equal(t, 1, imgCalls, "the same bytes are described once")
	assert.Equal(t, 1, st.Described)
	assert.Equal(t, 1, st.Copied)
	assert.Equal(t, 10, st.InTok)
	for _, id := range []int64{a, b} {
		r := e.row(id)
		assert.Equal(t, "ok", r.Status)
		assert.Equal(t, "Chart", r.Title)
		assert.Equal(t, "The image shows a bar chart.", r.Body)
		assert.Equal(t, "Q3 PROJ-7", r.ImageText)
		assert.True(t, strings.HasPrefix(r.ContentKey, "sha256:"))
		assert.Equal(t, "slack", r.KBSource)
		assert.NotEmpty(t, r.KBRef)
		assert.Empty(t, r.Error)
	}
	assert.NotEqual(t, e.row(a).KBRef, e.row(b).KBRef, "the copy computes its own parent's document")
	assert.Empty(t, e.tempEntries())
}

func TestPipeline_LinkDedupeBeforeFetch(t *testing.T) {
	e := newEnv(t)
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = io.WriteString(w, page(longText))
	}))
	t.Cleanup(srv.Close)
	e.web(map[string]*httptest.Server{"public.example": srv})
	a := e.link("1:C1", "1758000000.000100", "http://public.example/a")
	b := e.link("1:C1", "1758000000.000200", "http://public.example/a")

	st := e.run()

	assert.Equal(t, int32(1), hits.Load(), "the second link copies before any fetch")
	_, text := e.gen.calls()
	assert.Equal(t, 1, text)
	assert.Equal(t, 1, st.Described)
	assert.Equal(t, 1, st.Copied)
	for _, id := range []int64{a, b} {
		r := e.row(id)
		assert.Equal(t, "ok", r.Status)
		assert.Equal(t, "link", r.Kind)
		assert.Equal(t, "Example page", r.Title)
		assert.Equal(t, "The page describes the example.", r.Body)
		assert.NotEmpty(t, r.KBRef)
	}
}

func TestPipeline_LinkToImageDescribedAsImage(t *testing.T) {
	e := newEnv(t)
	img := noisePNG(t, 64, 64, 2)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(img)
	}))
	t.Cleanup(srv.Close)
	gets := e.web(map[string]*httptest.Server{"public.example": srv})
	id := e.link("1:C1", "1758000000.000100", "http://public.example/chart.png")
	urlImg := e.add("1:C1", "1758000000.000200", db.MediaFound{Kind: "image", Locator: "url:http://public.example/inline.png",
		FetchURL: "http://public.example/inline.png"}, false)

	e.run()

	assert.Equal(t, []string{
		"1m0s http://public.example/chart.png", "1m0s http://public.example/inline.png",
	}, gets(), "each URL is requested once, under the 60 s download timeout")
	assert.Equal(t, "ok", e.row(urlImg).Status)

	r := e.row(id)
	assert.Equal(t, "ok", r.Status)
	assert.Equal(t, "image", r.Kind)
	assert.True(t, strings.HasPrefix(r.ContentKey, "sha256:"))
	img1, text := e.gen.calls()
	assert.Equal(t, 1, img1, "the same bytes are described once")
	assert.Zero(t, text)
}

// A link is requested once: an image answer is read under the download
// timeout (past the link timeout), while a page is still cut at the link
// timeout.
func TestPipeline_LinkRequestedOnceImageOutlivesPageTimeout(t *testing.T) {
	prev := linkFetchTimeout
	linkFetchTimeout = 100 * time.Millisecond
	t.Cleanup(func() { linkFetchTimeout = prev })
	e := newEnv(t)
	img := noisePNG(t, 64, 64, 3)
	var imageHits, pageHits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/slow.png" {
			imageHits.Add(1)
			w.Header().Set("Content-Type", "image/png")
		} else {
			pageHits.Add(1)
			w.Header().Set("Content-Type", "text/html")
		}
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		select { // the body comes after the link timeout
		case <-time.After(300 * time.Millisecond):
		case <-r.Context().Done():
			return
		}
		if r.URL.Path == "/slow.png" {
			_, _ = w.Write(img)
			return
		}
		_, _ = w.Write([]byte(page(longText)))
	}))
	t.Cleanup(srv.Close)
	e.web(map[string]*httptest.Server{"public.example": srv})
	imgID := e.link("1:C1", "1758000000.000100", "http://public.example/slow.png")
	pageID := e.link("1:C1", "1758000000.000200", "http://public.example/slow-page")

	e.run()

	assert.EqualValues(t, 1, imageHits.Load(), "the image URL is requested exactly once")
	r := e.row(imgID)
	assert.Equal(t, "ok", r.Status)
	assert.Equal(t, "image", r.Kind)
	assert.EqualValues(t, 1, pageHits.Load())
	p := e.row(pageID)
	assert.Equal(t, "pending", p.Status, "a timed-out page waits for its next attempt")
	assert.Equal(t, "timeout", p.Error)
}

func TestPipeline_NoVisionMarksUnavailableWithoutOpening(t *testing.T) {
	e := newEnv(t)
	e.p.Gen = textOnlyGen{e.gen}
	id := e.image("1:C1", "1758000000.000100", "F1", noisePNG(t, 64, 64, 1))

	st := e.run()

	assert.Equal(t, "unavailable", e.row(id).Status)
	assert.Equal(t, 1, st.Unavailable)
	assert.Zero(t, e.op.count(), "no download without a vision-capable provider")
	assert.Empty(t, e.tempEntries())

	e.run()
	assert.Zero(t, e.op.count(), "an unavailable row is not listed again while there is no vision")
}

func TestPipeline_UnavailableRetriedWhenVisionArrives(t *testing.T) {
	e := newEnv(t)
	e.p.Gen = textOnlyGen{e.gen}
	id := e.image("1:C1", "1758000000.000100", "F1", noisePNG(t, 64, 64, 1))
	e.run()
	require.Equal(t, "unavailable", e.row(id).Status)

	e.p.Gen = e.gen
	e.run()

	assert.Equal(t, "ok", e.row(id).Status)
	assert.Equal(t, 1, e.op.count())
}

func heicBytes() []byte {
	b := append([]byte{0, 0, 0, 0x18}, []byte("ftypheic")...)
	return append(b, bytes.Repeat([]byte{7}, 4096)...)
}

func TestPipeline_JunkAndTypes(t *testing.T) {
	e := newEnv(t)
	sipsLog := stubSips(t, noiseJPEG(t, 64, 64))
	pixel := e.image("1:C1", "1758000000.000100", "pixel", solidPNG(t, 1, 1))
	small := e.image("1:C1", "1758000000.000200", "small", solidPNG(t, 40, 40))
	require.Less(t, len(solidPNG(t, 40, 40)), 2<<10)
	svg := e.image("1:C1", "1758000000.000300", "svg",
		[]byte(`<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg">`+strings.Repeat("<rect/>", 600)+`</svg>`))
	heic := e.image("1:C1", "1758000000.000400", "heic", heicBytes())

	st := e.run()

	assert.Equal(t, "skipped_junk", e.row(pixel).Status)
	assert.Equal(t, "skipped_junk", e.row(small).Status)
	assert.Equal(t, "skipped_type", e.row(svg).Status)
	assert.Equal(t, "ok", e.row(heic).Status)
	assert.Equal(t, 3, st.Skipped)
	assert.Equal(t, []string{"image/jpeg"}, e.gen.mediaTypes, "the HEIC is sent as the converted JPEG")
	assert.Contains(t, readLog(t, sipsLog), "-s format jpeg")
	assert.Empty(t, e.tempEntries())
}

func TestPipeline_DownscalesOversized(t *testing.T) {
	e := newEnv(t)
	sipsLog := stubSips(t, noiseJPEG(t, 64, 64))
	wide := e.image("1:C1", "1758000000.000100", "wide", noisePNG(t, 8100, 20, 3))

	e.run()

	assert.Equal(t, "ok", e.row(wide).Status)
	assert.Contains(t, readLog(t, sipsLog), "-s format jpeg -Z 2048")
	assert.Equal(t, []string{"image/jpeg"}, e.gen.mediaTypes)
}

func TestPipeline_TooLargeAndGone(t *testing.T) {
	e := newEnv(t)
	big := e.image("1:C1", "1758000000.000100", "big", nil)
	e.op.errs["big"] = ErrTooLarge
	gone := e.image("1:C1", "1758000000.000200", "gone", nil)
	e.op.errs["gone"] = ErrGone
	stream := e.image("1:C1", "1758000000.000300", "stream", nil)
	e.op.read["stream"] = func() io.Reader { return io.LimitReader(zeroReader{}, maxMediaDownload+1) }

	e.run()

	assert.Equal(t, "too_large", e.row(big).Status)
	assert.Equal(t, "unreachable", e.row(gone).Status)
	assert.Equal(t, "not_found", e.row(gone).Error)
	assert.Equal(t, "too_large", e.row(stream).Status, "a body over the cap is refused even when the opener did not know the size")
	img, _ := e.gen.calls()
	assert.Zero(t, img)
	assert.Empty(t, e.tempEntries())
}

type zeroReader struct{}

func (zeroReader) Read(p []byte) (int, error) {
	clear(p)
	return len(p), nil
}

func TestPipeline_FailsAfterThreeAttempts(t *testing.T) {
	e := newEnv(t)
	id := e.image("1:C1", "1758000000.000100", "F1", nil)
	e.op.errs["F1"] = errors.New("connection reset")

	for i := 1; i <= 3; i++ {
		st := e.run()
		assert.Equal(t, 1, st.Failed)
		assert.Equal(t, i, e.row(id).Attempts)
	}
	assert.Equal(t, "failed", e.row(id).Status)
	assert.Equal(t, "other", e.row(id).Error)

	e.run()
	assert.Equal(t, 3, e.op.count(), "a failed row is never listed again")
}

func TestPipeline_TempFilesRemovedOnEveryPath(t *testing.T) {
	e := newEnv(t)
	var sawFile atomic.Bool
	e.gen.describe = func(_ context.Context, path, _ string) (string, error) {
		if _, err := os.Stat(path); err == nil && strings.HasPrefix(path, tempDir(e.ws)) {
			sawFile.Store(true)
		}
		e.gen.mu.Lock()
		n := e.gen.imageCalls
		e.gen.mu.Unlock()
		if n == 2 {
			panic("describer blew up")
		}
		return `{"title":"T","description":"The image shows a thing.","text":"","keys":[]}`, nil
	}
	ok := e.image("1:C1", "1758000000.000100", "ok", noisePNG(t, 64, 64, 1))
	broken := e.image("1:C1", "1758000000.000200", "broken", nil)
	e.op.read["broken"] = func() io.Reader {
		return io.MultiReader(bytes.NewReader(noisePNG(t, 64, 64, 2)[:3000]), errReader{})
	}
	panicky := e.image("1:C1", "1758000000.000300", "panic", noisePNG(t, 64, 64, 3))

	st := e.run()

	assert.True(t, sawFile.Load(), "the image is sent from the temp dir")
	assert.Equal(t, "ok", e.row(ok).Status)
	assert.Equal(t, 1, e.row(broken).Attempts)
	assert.Equal(t, 1, e.row(panicky).Attempts, "a panicking describer is a failed attempt")
	assert.Equal(t, "model_error", e.row(panicky).Error)
	assert.Equal(t, 2, st.Failed)
	assert.Empty(t, e.tempEntries(), "no temp file survives success, error or panic")
}

type errReader struct{}

func (errReader) Read([]byte) (int, error) { return 0, errors.New("stream broke") }

func TestPipeline_SweepsStaleTempFiles(t *testing.T) {
	e := newEnv(t)
	dir := tempDir(e.ws)
	require.NoError(t, os.MkdirAll(dir, 0o700))
	old := filepath.Join(dir, "media-old")
	fresh := filepath.Join(dir, "media-fresh")
	oldDir := filepath.Join(dir, "media-call-old")
	other := filepath.Join(dir, "keep-me")
	for _, f := range []string{old, fresh, other} {
		require.NoError(t, os.WriteFile(f, []byte("x"), 0o600))
	}
	require.NoError(t, os.Mkdir(oldDir, 0o700))
	past := time.Now().Add(-11 * time.Minute)
	for _, f := range []string{old, other, oldDir} {
		require.NoError(t, os.Chtimes(f, past, past))
	}

	e.run()

	assert.NoFileExists(t, old)
	assert.NoDirExists(t, oldDir)
	assert.FileExists(t, fresh)
	assert.FileExists(t, other, "only media-* entries are swept")
	info, err := os.Stat(dir)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o700), info.Mode().Perm())
}

func TestPipeline_HungDescriberCutAtDeadline(t *testing.T) {
	e := newEnv(t)
	prev := describeTimeout
	describeTimeout = 50 * time.Millisecond
	t.Cleanup(func() { describeTimeout = prev })
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	e.gen.describe = func(context.Context, string, string) (string, error) {
		<-release // ignores ctx
		return "", errors.New("released")
	}
	id := e.image("1:C1", "1758000000.000100", "F1", noisePNG(t, 64, 64, 1))

	done := make(chan Stats, 1)
	go func() {
		st, _ := e.p.Run(context.Background(), time.Minute)
		done <- st
	}()
	select {
	case st := <-done:
		assert.Equal(t, 1, st.Failed)
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return after the describe deadline")
	}
	r := e.row(id)
	assert.Equal(t, 1, r.Attempts)
	assert.Equal(t, "timeout", r.Error)
	assert.Equal(t, "pending", r.Status)
}

// fakeClock advances by step on each describe call.
type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

func TestPipeline_BudgetStopsNewItems(t *testing.T) {
	e := newEnv(t)
	clock := &fakeClock{now: time.Now()}
	e.p.Now = clock.Now
	e.gen.afterCall = func() { clock.advance(time.Minute) }
	a := e.image("1:C1", "1758000000.000100", "A", noisePNG(t, 64, 64, 1))
	b := e.image("1:C1", "1758000000.000200", "B", noisePNG(t, 64, 64, 2))

	st, err := e.p.Run(context.Background(), 30*time.Second)
	require.NoError(t, err)

	assert.True(t, st.Incomplete)
	assert.Equal(t, "ok", e.row(a).Status, "the started item finishes")
	assert.Equal(t, "pending", e.row(b).Status)
}

func TestPipeline_OwnerItemsFirst(t *testing.T) {
	e := newEnv(t)
	prev := mediaBatch
	mediaBatch = 1
	t.Cleanup(func() { mediaBatch = prev })
	clock := &fakeClock{now: time.Now()}
	e.p.Now = clock.Now
	e.gen.afterCall = func() { clock.advance(time.Minute) }
	other := e.image("1:C1", "1758000000.000100", "other", noisePNG(t, 64, 64, 1))
	e.op.data["mine"] = noisePNG(t, 64, 64, 2)
	e.msg("1:C1", "1758000000.000200", "")
	mine := e.record("1:C1", "1758000000.000200", db.MediaFound{Kind: "image", Locator: "mine", MediaType: "image/png"}, true)
	require.Greater(t, mine, other)

	st, err := e.p.Run(context.Background(), 30*time.Second)
	require.NoError(t, err)

	assert.True(t, st.Incomplete)
	assert.Equal(t, "ok", e.row(mine).Status, "the owner's newer item goes first")
	assert.Equal(t, "pending", e.row(other).Status)
}

func TestPipeline_LoginPageUnreachable(t *testing.T) {
	e := newEnv(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		_, _ = io.WriteString(w, `<html><head><title>Sign in</title></head><body><p>`+longText+
			`</p><form><input name="u"><input TYPE=" Password " name="p"></form></body></html>`)
	}))
	t.Cleanup(srv.Close)
	short := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		_, _ = io.WriteString(w, page("Too short to summarize."))
	}))
	t.Cleanup(short.Close)
	e.web(map[string]*httptest.Server{"login.example": srv, "short.example": short})
	login := e.link("1:C1", "1758000000.000100", "http://login.example/")
	tiny := e.link("1:C1", "1758000000.000200", "http://short.example/")

	e.run()

	assert.Equal(t, "unreachable", e.row(login).Status)
	assert.Equal(t, "unreachable", e.row(tiny).Status)
	_, text := e.gen.calls()
	assert.Zero(t, text, "a login page or a near-empty page is never sent to the model")
}

func TestPipeline_BelowStartMarkNeverTouched(t *testing.T) {
	e := newEnv(t)
	id := e.image("1:C1", "1758000000.000100", "F1", noisePNG(t, 64, 64, 1))
	require.NoError(t, e.d.SetMediaStartAt(time.Now().Add(time.Hour)))

	e.run()

	r := e.row(id)
	assert.Equal(t, "pending", r.Status)
	assert.Zero(t, r.Attempts)
	assert.Zero(t, e.op.count())
}

func TestPipeline_DedupeScopedByAccount(t *testing.T) {
	e := newEnv(t)
	img := noisePNG(t, 64, 64, 1)
	a1 := e.image("1:C1", "1758000000.000100", "F1", img)
	a2 := e.image("2:C1", "1758000000.000100", "F1", img)
	a1copy := e.image("1:C1", "1758200000.000100", "F2", img)

	st := e.run()

	imgCalls, _ := e.gen.calls()
	assert.Equal(t, 2, imgCalls, "bytes seen in another account are described again")
	assert.Equal(t, 1, st.Copied)
	for _, id := range []int64{a1, a2, a1copy} {
		assert.Equal(t, "ok", e.row(id).Status)
		assert.Empty(t, e.row(id).Error)
	}
	assert.NotEqual(t, e.row(a1).KBRef, e.row(a1copy).KBRef)
	assert.True(t, strings.HasPrefix(e.row(a2).KBRef, "2:C1") || strings.Contains(e.row(a2).KBRef, "2:C1"))
}

func TestPipeline_StoresOnlyErrorClass(t *testing.T) {
	e := newEnv(t)
	id := e.image("1:C1", "1758000000.000100", "F1", nil)
	e.op.errs["F1"] = errors.New("GET https://x.example/?token=s3cret: connection reset")

	e.run()

	r := e.row(id)
	assert.Contains(t, []string{"refused", "other"}, r.Error)
	rows, err := e.d.Query(`SELECT * FROM media_items WHERE id = ?`, id)
	require.NoError(t, err)
	defer rows.Close()
	cols, err := rows.Columns()
	require.NoError(t, err)
	require.True(t, rows.Next())
	vals := make([]any, len(cols))
	ptrs := make([]any, len(cols))
	for i := range vals {
		ptrs[i] = &vals[i]
	}
	require.NoError(t, rows.Scan(ptrs...))
	for i, v := range vals {
		assert.NotContains(t, fmt.Sprint(v), "s3cret", "column %s", cols[i])
		if b, ok := v.([]byte); ok {
			assert.NotContains(t, string(b), "s3cret", "column %s", cols[i])
		}
	}
	assert.NotContains(t, e.log.String(), "s3cret", "the log cuts the query")
	assert.Contains(t, e.log.String(), "https://x.example/")
}

// TestPipeline_DenyHostRefusedOnRedirect is a unit test of the composition:
// the pass's check holds the deny list and refuses a redirect hop to a denied
// host. The test fetcher runs that check the way webfetch.Fetcher does
// (Task 3's tests pin the fetcher's own redirect re-check).
func TestPipeline_DenyHostRefusedOnRedirect(t *testing.T) {
	e := newEnv(t)
	e.p.DenyHosts = []string{"Denied.Example"}
	var deniedHits atomic.Int32
	denied := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		deniedHits.Add(1)
		w.Header().Set("Content-Type", "text/html")
		_, _ = io.WriteString(w, page(longText))
	}))
	t.Cleanup(denied.Close)
	public := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://wiki.denied.example/secret", http.StatusFound)
	}))
	t.Cleanup(public.Close)
	e.web(map[string]*httptest.Server{"public.example": public, "wiki.denied.example": denied})
	id := e.link("1:C1", "1758000000.000100", "http://public.example/go")

	e.run()

	r := e.row(id)
	assert.Equal(t, "unreachable", r.Status)
	assert.Equal(t, "refused", r.Error)
	assert.Zero(t, deniedHits.Load(), "the denied host is never contacted")
}

func TestPipeline_ShutdownSpendsNoAttempt(t *testing.T) {
	e := newEnv(t)
	ctx, cancel := context.WithCancel(context.Background())
	e.gen.describe = func(context.Context, string, string) (string, error) {
		cancel()
		return "", context.Canceled
	}
	id := e.image("1:C1", "1758000000.000100", "F1", noisePNG(t, 64, 64, 1))

	_, err := e.p.Run(ctx, time.Minute)

	assert.ErrorIs(t, err, context.Canceled)
	assert.Zero(t, e.row(id).Attempts)
	assert.Equal(t, "pending", e.row(id).Status)
}

// TestKB01_PromotedParentRedoEqualsReindex: a top-level message's image is
// described into the day document; the message gains a reply (it now
// renders into its thread document); the description is redone. The pass
// stores the parent's current document, so the incremental index equals a
// from-scratch rebuild and the old description is gone everywhere.
func TestKB01_PromotedParentRedoEqualsReindex(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	now := time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)
	root := "1758000000.000100"
	id := e.image("1:C1", root, "F1", noisePNG(t, 64, 64, 1))
	e.gen.describe = func(context.Context, string, string) (string, error) {
		return `{"title":"Chart","description":"первое описание скриншота","text":"","keys":[]}`, nil
	}
	e.run()
	dayRef := e.row(id).KBRef
	require.NotEmpty(t, dayRef)
	_, err := kb.Run(ctx, e.d, kb.Options{Now: now})
	require.NoError(t, err)
	require.Contains(t, dumpKB(t, e.d), "первое описание скриншота")

	// Promotion: the root becomes a thread root and gains a reply.
	e.exec(`UPDATE messages SET thread_ts = ts WHERE channel_id = '1:C1' AND ts = ?`, root)
	e.msg("1:C1", "1758000100.000200", root)
	_, err = kb.Run(ctx, e.d, kb.Options{Now: now.Add(time.Hour)})
	require.NoError(t, err)

	// Redo: the row goes back to pending and is described again.
	e.exec(`UPDATE media_items SET status = 'pending' WHERE id = ?`, id)
	e.gen.describe = func(context.Context, string, string) (string, error) {
		return `{"title":"Chart","description":"второе описание скриншота","text":"","keys":[]}`, nil
	}
	e.run()
	r := e.row(id)
	require.Equal(t, "ok", r.Status)
	assert.NotEqual(t, dayRef, r.KBRef, "the parent's current (thread) document is stored")
	src, ref, err := kb.MediaParentRef(ctx, e.d, db.MediaItem{ID: id, ParentKind: "slack", SlackChannelID: "1:C1", SlackTS: root})
	require.NoError(t, err)
	assert.Equal(t, src+"|"+ref, r.KBSource+"|"+r.KBRef)

	later := now.Add(2 * time.Hour)
	_, err = kb.Run(ctx, e.d, kb.Options{Now: later})
	require.NoError(t, err)
	incremental := dumpKB(t, e.d)
	assert.Contains(t, incremental, "второе описание скриншота")
	assert.NotContains(t, incremental, "первое описание скриншота")

	_, err = kb.Reindex(ctx, e.d, nil, later)
	require.NoError(t, err)
	assert.Equal(t, incremental, dumpKB(t, e.d), "incremental indexing equals a from-scratch rebuild")
}

func dumpKB(t *testing.T, d *db.DB) string {
	t.Helper()
	var b strings.Builder
	for _, q := range []string{
		`SELECT id || '|' || source || '|' || title || '|' || content_hash || '|' || chunk_count FROM kb_documents WHERE source <> 'guide' ORDER BY id`,
		`SELECT c.doc_id || '|' || c.idx || '|' || c.body FROM kb_chunks c JOIN kb_documents k ON k.id = c.doc_id WHERE k.source <> 'guide' ORDER BY c.doc_id, c.idx`,
	} {
		func() {
			rows, err := d.Query(q)
			require.NoError(t, err)
			defer func() { _ = rows.Close() }()
			for rows.Next() {
				var s string
				require.NoError(t, rows.Scan(&s))
				b.WriteString(s + "\n")
			}
			require.NoError(t, rows.Err())
		}()
		b.WriteString("--\n")
	}
	return b.String()
}

// --- local opener -----------------------------------------------------------

func localRoots(t *testing.T) (root string, o LocalOpener) {
	t.Helper()
	ws := t.TempDir()
	root = filepath.Join(ws, "chat_files")
	require.NoError(t, os.MkdirAll(filepath.Join(root, "conversations", "1"), 0o700))
	require.NoError(t, os.MkdirAll(filepath.Join(ws, "project_files"), 0o700))
	return root, LocalOpener{Roots: []string{root, filepath.Join(ws, "project_files")}}
}

func openLocal(o LocalOpener, path string) (io.ReadCloser, error) {
	rc, _, err := o.Open(context.Background(), db.MediaItem{Locator: path, MediaType: "image/png"}, maxMediaDownload)
	return rc, err
}

func TestLocalOpener_RefusesOutsideRoots(t *testing.T) {
	root, o := localRoots(t)
	inside := filepath.Join(root, "conversations", "1", "a.png")
	require.NoError(t, os.WriteFile(inside, []byte("png bytes"), 0o600))
	rc, err := openLocal(o, inside)
	require.NoError(t, err)
	b, _ := io.ReadAll(rc)
	_ = rc.Close()
	assert.Equal(t, "png bytes", string(b))

	outside := filepath.Join(t.TempDir(), "secret.png")
	require.NoError(t, os.WriteFile(outside, []byte("secret"), 0o600))
	link := filepath.Join(root, "conversations", "1", "link.png")
	require.NoError(t, os.Symlink(outside, link))
	_, err = openLocal(o, link)
	assert.ErrorIs(t, err, ErrGone)
	_, err = openLocal(o, outside)
	assert.ErrorIs(t, err, ErrGone)
	_, err = openLocal(o, filepath.Join(root, "..", "chat_files_evil", "x.png"))
	assert.ErrorIs(t, err, ErrGone)
	_, err = openLocal(o, "conversations/1/a.png")
	assert.ErrorIs(t, err, ErrGone, "a relative locator is refused")
	_, err = openLocal(o, root)
	assert.ErrorIs(t, err, ErrGone, "the root itself is no file")
}

func TestLocalOpener_NoFollowRegularOnly(t *testing.T) {
	root, o := localRoots(t)
	fifo := filepath.Join(root, "conversations", "1", "pipe.png")
	require.NoError(t, syscall.Mkfifo(fifo, 0o600))
	done := make(chan error, 1)
	go func() { _, err := openLocal(o, fifo); done <- err }()
	select {
	case err := <-done:
		assert.ErrorIs(t, err, ErrGone)
	case <-time.After(3 * time.Second):
		t.Fatal("opening a FIFO blocked")
	}

	_, err := openLocal(o, filepath.Join(root, "conversations"))
	assert.ErrorIs(t, err, ErrGone, "a directory is no regular file")

	// A symlink swapped in after the root check is refused by O_NOFOLLOW.
	file := filepath.Join(root, "conversations", "1", "b.png")
	require.NoError(t, os.WriteFile(file, []byte("ok"), 0o600))
	outside := filepath.Join(t.TempDir(), "secret.png")
	require.NoError(t, os.WriteFile(outside, []byte("secret"), 0o600))
	beforeLocalOpen = func(path string) {
		_ = os.Remove(path)
		_ = os.Symlink(outside, path)
	}
	t.Cleanup(func() { beforeLocalOpen = nil })
	_, err = openLocal(o, file)
	assert.ErrorIs(t, err, ErrGone)
}

func TestLocalOpener_TooLarge(t *testing.T) {
	root, o := localRoots(t)
	file := filepath.Join(root, "conversations", "1", "c.png")
	require.NoError(t, os.WriteFile(file, make([]byte, 100), 0o600))
	_, _, err := o.Open(context.Background(), db.MediaItem{Locator: file}, 99)
	assert.ErrorIs(t, err, ErrTooLarge)
}

// --- sips, sniffing, policy, classes ----------------------------------------

func TestRunSips_TimeoutKillsGroup(t *testing.T) {
	dir := t.TempDir()
	parentPID := filepath.Join(dir, "parent.pid")
	childPID := filepath.Join(dir, "child.pid")
	script := filepath.Join(dir, "sips")
	body := "#!/bin/sh\necho $$ > '" + parentPID + "'\nsleep 30 &\necho $! > '" + childPID +
		"'\nfor a; do last=$a; done\necho partial > \"$last\"\nwait\n"
	require.NoError(t, os.WriteFile(script, []byte(body), 0o700))
	prevPath, prevTimeout := sipsPath, sipsTimeout
	sipsPath, sipsTimeout = script, 300*time.Millisecond
	t.Cleanup(func() { sipsPath, sipsTimeout = prevPath, prevTimeout })
	work := filepath.Join(dir, "work")
	require.NoError(t, os.Mkdir(work, 0o700))
	in := filepath.Join(work, "media-in")
	require.NoError(t, os.WriteFile(in, []byte("x"), 0o600))
	t.Cleanup(func() {
		for _, f := range []string{parentPID, childPID} {
			if pid := readPID(f); pid > 0 {
				_ = syscall.Kill(pid, syscall.SIGKILL)
			}
		}
	})

	out, err := runSips(context.Background(), in, "-s", "format", "jpeg")

	require.Error(t, err)
	assert.Empty(t, out)
	assert.Equal(t, "convert_failed", ClassifyError(err))
	for _, f := range []string{parentPID, childPID} {
		pid := readPID(f)
		require.Positive(t, pid, f)
		assert.Eventually(t, func() bool { return errors.Is(syscall.Kill(pid, 0), syscall.ESRCH) },
			3*time.Second, 20*time.Millisecond, "process %d is gone", pid)
	}
	entries, err := os.ReadDir(work)
	require.NoError(t, err)
	require.Len(t, entries, 1, "the partial output file is removed, never reused")
	assert.Equal(t, "media-in", entries[0].Name())
}

func readPID(path string) int {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	n, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	return n
}

// hugePNG is a PNG signature and IHDR declaring w×h, then filler and no
// image data at all.
func hugePNG(w, h uint32) []byte {
	var b bytes.Buffer
	b.WriteString("\x89PNG\r\n\x1a\n")
	ihdr := make([]byte, 13)
	binary.BigEndian.PutUint32(ihdr[0:], w)
	binary.BigEndian.PutUint32(ihdr[4:], h)
	ihdr[8], ihdr[9] = 8, 6 // 8-bit RGBA
	_ = binary.Write(&b, binary.BigEndian, uint32(len(ihdr)))
	chunk := append([]byte("IHDR"), ihdr...)
	b.Write(chunk)
	_ = binary.Write(&b, binary.BigEndian, crc32.ChecksumIEEE(chunk))
	b.Write(bytes.Repeat([]byte{0}, 4096))
	return b.Bytes()
}

func TestSniff_HeadersOnly(t *testing.T) {
	path := filepath.Join(t.TempDir(), "media-huge")
	require.NoError(t, os.WriteFile(path, hugePNG(100000, 100000), 0o600))
	mt, w, h, err := sniffImage(path)
	require.NoError(t, err)
	assert.Equal(t, "image/png", mt)
	assert.Equal(t, 100000, w)
	assert.Equal(t, 100000, h)

	e := newEnv(t)
	sipsLog := stubSips(t, noiseJPEG(t, 64, 64))
	id := e.image("1:C1", "1758000000.000100", "huge", hugePNG(100000, 100000))
	e.run()
	assert.Equal(t, "too_large", e.row(id).Status)
	assert.Empty(t, readLog(t, sipsLog), "a decompression bomb is never handed to sips")
}

func TestSniff_Types(t *testing.T) {
	webpVP8X := append([]byte("RIFF\x00\x00\x00\x00WEBPVP8X"), make([]byte, 14)...)
	webpVP8X[24], webpVP8X[27] = 99, 49 // 100×50
	for _, c := range []struct {
		name string
		head []byte
		want string
	}{
		{"png", noisePNG(t, 2, 2, 1), "image/png"},
		{"jpeg", noiseJPEG(t, 8, 8), "image/jpeg"},
		{"webp", webpVP8X, "image/webp"},
		{"heic", heicBytes(), "image/heic"},
		{"tiff", []byte("II*\x00rest"), "image/tiff"},
		{"svg", []byte(`<svg xmlns="http://www.w3.org/2000/svg"></svg>`), ""},
		{"pdf", []byte("%PDF-1.7"), ""},
	} {
		assert.Equal(t, c.want, sniffType(c.head), c.name)
	}
	w, h, ok := webpSize(webpVP8X)
	assert.True(t, ok)
	assert.Equal(t, []int{100, 50}, []int{w, h})
}

func TestDenyHosts_ConfigUnitesWithBuildSeed(t *testing.T) {
	prev := BuildDenyHosts
	BuildDenyHosts = "corp.example, tenant.example,,"
	t.Cleanup(func() { BuildDenyHosts = prev })

	withList := &config.Config{Knowledge: config.KnowledgeConfig{LinkFetchDenyHosts: []string{" extra.example ", ""}}}
	assert.Equal(t, []string{"corp.example", "tenant.example", "extra.example"}, DenyHosts(withList))
	assert.Equal(t, []string{"corp.example", "tenant.example"}, DenyHosts(&config.Config{}))
	assert.Equal(t, []string{"corp.example", "tenant.example"}, DenyHosts(nil))

	set := linkrule.NormalizeHostSet(DenyHosts(withList))
	for _, raw := range []string{"https://corp.example/x", "https://wiki.tenant.example/", "https://EXTRA.example./a"} {
		_, ok := linkrule.Fetchable(raw, set)
		assert.False(t, ok, raw)
	}
}

func TestClassifyError(t *testing.T) {
	for _, c := range []struct {
		err  error
		want string
	}{
		{context.DeadlineExceeded, "timeout"},
		{fmt.Errorf("x: %w", context.Canceled), "canceled"},
		{webfetch.ErrRefused, "refused"},
		{webfetch.ErrNotFound, "not_found"},
		{ErrGone, "not_found"},
		{webfetch.ErrTooLarge, "too_large"},
		{webfetch.ErrUnsupported, "unsupported"},
		{modelError{ErrBadOutput}, "bad_output"},
		{modelError{errors.New("exit 1")}, "model_error"},
		{modelError{context.DeadlineExceeded}, "timeout"},
		{convertError{context.DeadlineExceeded}, "convert_failed"},
		{openError{errors.New("disk full")}, "open_failed"},
		{errors.New("whatever"), "other"},
	} {
		got := ClassifyError(c.err)
		assert.Equal(t, c.want, got, c.err.Error())
		assert.Contains(t, ErrorClasses, got)
	}
	assert.Equal(t, "GET https://x.example/a?… boom", redactURLs("GET https://x.example/a?token=s3cret#f: boom"))
}

// fakeResolver answers every item with target/err.
type fakeResolver struct {
	target *db.MediaItem
	err    error
}

func (f fakeResolver) Resolve(context.Context, db.MediaItem) (*db.MediaItem, error) {
	return f.target, f.err
}

func TestPipeline_Resolver(t *testing.T) {
	for _, c := range []struct {
		name            string
		res             fakeResolver
		status, errCls  string
		attempts, opens int
		described       bool
	}{
		{name: "nil target opens as usual", status: "ok", opens: 1, described: true},
		{name: "ok target copied", res: fakeResolver{target: &db.MediaItem{Status: "ok", ContentKey: "sha256:abc",
			Title: "Diagram", Body: "The image shows a flow.", ImageText: "A -> B", Keys: []string{}}}, status: "ok"},
		{name: "pending target waits", res: fakeResolver{target: &db.MediaItem{Status: "pending"}}, status: "pending"},
		{name: "unavailable target waits", res: fakeResolver{target: &db.MediaItem{Status: "unavailable"}}, status: "pending"},
		{name: "failed target unreachable", res: fakeResolver{target: &db.MediaItem{Status: "failed"}}, status: "unreachable", errCls: "not_found"},
		{name: "gone unreachable", res: fakeResolver{err: ErrGone}, status: "unreachable", errCls: "not_found"},
		{name: "other error is an attempt", res: fakeResolver{err: errors.New("db busy")}, status: "pending", errCls: "other", attempts: 1},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newEnv(t)
			e.p.Resolvers = map[string]Resolver{"slack": c.res}
			id := e.image("1:C1", "1758000000.000100", "F1", noisePNG(t, 64, 64, 1))

			e.run()

			r := e.row(id)
			assert.Equal(t, c.status, r.Status)
			assert.Equal(t, c.errCls, r.Error)
			assert.Equal(t, c.attempts, r.Attempts)
			assert.Equal(t, c.opens, e.op.count())
			img, _ := e.gen.calls()
			assert.Equal(t, c.described, img == 1)
			if c.res.target != nil && c.res.target.Status == "ok" {
				assert.Equal(t, "sha256:abc", r.ContentKey, "the copy carries the target's content key")
				assert.Equal(t, "The image shows a flow.", r.Body)
				assert.Equal(t, "A -> B", r.ImageText)
				assert.NotEmpty(t, r.KBRef, "the copy computes its own parent's document")
			}
		})
	}
}

func TestPipeline_NonOKStoresNoKBRef(t *testing.T) {
	e := newEnv(t)
	gone := e.image("1:C1", "1758000000.000100", "gone", nil)
	e.op.errs["gone"] = ErrGone
	junk := e.image("1:C1", "1758000000.000200", "junk", solidPNG(t, 1, 1))

	e.run()

	for _, id := range []int64{gone, junk} {
		r := e.row(id)
		assert.NotEqual(t, "ok", r.Status)
		assert.Empty(t, r.KBRef)
		assert.Empty(t, r.KBSource)
	}
}

func TestPipeline_HEICJunkJudgesOriginalSize(t *testing.T) {
	e := newEnv(t)
	stubSips(t, noiseJPEG(t, 64, 64)) // the converted JPEG is well over 2 KiB
	tiny := append([]byte{0, 0, 0, 0x18}, []byte("ftypheic")...)
	tiny = append(tiny, bytes.Repeat([]byte{7}, 1000)...)
	id := e.image("1:C1", "1758000000.000100", "tiny", tiny)

	e.run()

	assert.Equal(t, "skipped_junk", e.row(id).Status)
	img, _ := e.gen.calls()
	assert.Zero(t, img)
}

func TestPipeline_OpenerPanicIsAFailedAttempt(t *testing.T) {
	e := newEnv(t)
	id := e.image("1:C1", "1758000000.000100", "F1", nil)
	e.op.read["F1"] = func() io.Reader { return panicReader{} }

	st := e.run()

	r := e.row(id)
	assert.Equal(t, "pending", r.Status)
	assert.Equal(t, 1, r.Attempts)
	assert.Equal(t, "other", r.Error)
	assert.Equal(t, 1, st.Failed)
	assert.Empty(t, e.tempEntries(), "the temp file is removed after the panic")
}

type panicReader struct{}

func (panicReader) Read([]byte) (int, error) { panic("opener blew up") }

func TestPipeline_AfterDescribedHooks(t *testing.T) {
	e := newEnv(t)
	var seen []db.MediaItem
	e.p.AfterDescribed = []func(context.Context, db.MediaItem) error{
		func(_ context.Context, it db.MediaItem) error { seen = append(seen, it); return nil },
		func(context.Context, db.MediaItem) error { return errors.New("hook failed") },
	}
	ok := e.image("1:C1", "1758000000.000100", "ok", noisePNG(t, 64, 64, 1))
	e.image("1:C1", "1758000000.000200", "junk", solidPNG(t, 1, 1))

	e.run()

	require.Len(t, seen, 1, "hooks run for ok results only")
	got := seen[0]
	assert.Equal(t, ok, got.ID)
	assert.Equal(t, "ok", got.Status)
	assert.Equal(t, "Q3 PROJ-7", got.ImageText)
	assert.Equal(t, []string{"PROJ-7"}, got.Keys)
	assert.Equal(t, e.row(ok).KBRef, got.KBRef)
	assert.True(t, strings.HasPrefix(got.ContentKey, "sha256:"))
	assert.Contains(t, e.log.String(), "hook failed", "a hook error is logged")
	assert.Equal(t, "ok", e.row(ok).Status, "a hook error changes nothing stored")
}

func TestPipeline_HasPending(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	has, err := e.p.HasPending(ctx)
	require.NoError(t, err)
	assert.False(t, has)

	e.p.Gen = textOnlyGen{e.gen}
	id := e.image("1:C1", "1758000000.000100", "F1", noisePNG(t, 64, 64, 1))
	has, err = e.p.HasPending(ctx)
	require.NoError(t, err)
	assert.True(t, has)

	e.run()
	require.Equal(t, "unavailable", e.row(id).Status)
	has, err = e.p.HasPending(ctx)
	require.NoError(t, err)
	assert.False(t, has, "an unavailable image waits while there is no vision")

	e.p.Gen = e.gen
	has, err = e.p.HasPending(ctx)
	require.NoError(t, err)
	assert.True(t, has, "it is pending work once vision is configured")
}
