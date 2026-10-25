package media

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/net/html"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/doclinks"
	"watchtower/internal/extract"
	"watchtower/internal/kb"
	"watchtower/internal/media/webfetch"
	"watchtower/internal/prompts"
)

// The pass's limits (vars so tests shrink them).
var (
	mediaBatch           = 10
	imageDownloadTimeout = 60 * time.Second
	describeTimeout      = 120 * time.Second
	summaryTimeout       = 60 * time.Second
)

const (
	// maxMediaAttempts failed attempts end a row 'failed', never retried.
	maxMediaAttempts = 3
	// maxPageBytes caps the page body read for a summary.
	maxPageBytes = 2 << 20
	// minPageRunes: a page with less text has nothing worth summarizing.
	minPageRunes = 200
)

// Pipeline is the media describe pass: it works the pending media_items
// rows, owner items first, into stored descriptions and summaries. Bytes
// land only in <WorkspaceDir>/tmp/media and are removed before the item's
// result is written; every model call runs outside any write transaction.
type Pipeline struct {
	DB      *db.DB
	Gen     digest.Generator
	Prompts *prompts.Store
	// DenyHosts are the hosts whose links are never fetched (DenyHosts(cfg)),
	// added to SyncedHosts and the connected Jira sites at each run.
	DenyHosts []string
	// Openers and Resolvers are keyed by the item's parent kind.
	Openers   map[string]Opener
	Resolvers map[string]Resolver
	// AfterDescribed run after an item is stored 'ok', with the stored
	// result; a hook error is logged.
	AfterDescribed []func(ctx context.Context, it db.MediaItem) error
	WorkspaceDir   string
	Now            func() time.Time
	Logger         *log.Logger

	// newWeb builds the run's web fetcher over check; nil = webfetch.New.
	newWeb func(check func(string) bool) webGetter
}

// webGetter is the web fetch the pass needs (webfetch.Fetcher).
type webGetter interface {
	Get(ctx context.Context, rawURL string, maxBytes int64) (*webfetch.Response, error)
}

// Stats are one run's counts. Skipped holds every terminal status other
// than ok and unavailable; Failed counts failed attempts.
type Stats struct {
	Described, Copied, Skipped, Failed, Unavailable int
	InTok, OutTok                                   int
	Cost                                            float64
	Incomplete                                      bool
}

func (p *Pipeline) now() time.Time {
	if p.Now != nil {
		return p.Now()
	}
	return time.Now()
}

func (p *Pipeline) logf(format string, args ...any) {
	if p.Logger != nil {
		p.Logger.Printf(format, args...)
	}
}

// Run works pending rows until none is left, ctx ends or budget is spent
// (checked before each new item; a started item finishes).
func (p *Pipeline) Run(ctx context.Context, budget time.Duration) (Stats, error) {
	var st Stats
	if p.DB == nil || p.Gen == nil || p.WorkspaceDir == "" {
		return st, errors.New("media: the pass needs a database, a generator and a workspace")
	}
	start := p.now()
	dir := tempDir(p.WorkspaceDir)
	if err := makeTempDir(dir); err != nil {
		return st, err
	}
	if err := sweepTempDir(dir, start); err != nil {
		p.logf("media: %v", err)
	}
	refused, err := p.refusedHosts(ctx)
	if err != nil {
		return st, err
	}
	check := func(u string) bool { _, ok := Fetchable(u, refused); return ok }
	r := &run{p: p, dir: dir, st: &st, ext: &extract.Extractor{}}
	if p.newWeb != nil {
		r.web = p.newWeb(check)
	} else {
		r.web = webfetch.New(check) // one per run: own addresses read afresh
	}
	r.ig, r.vision = digest.ImageCapable(p.Gen)

	var cursor db.MediaCursor
	for {
		if err := ctx.Err(); err != nil {
			return st, err
		}
		items, err := p.DB.ListPendingMedia(ctx, r.vision, cursor, mediaBatch)
		if err != nil {
			return st, err
		}
		if len(items) == 0 {
			return st, nil
		}
		for _, it := range items {
			if p.now().Sub(start) >= budget {
				st.Incomplete = true
				return st, nil
			}
			if err := ctx.Err(); err != nil {
				return st, err
			}
			cursor = db.MediaCursor{FromOwner: it.FromOwner, ID: it.ID}
			r.item(ctx, it)
		}
	}
}

// refusedHosts is this run's refused-host set: the synced sources, the
// connected Jira/Confluence sites and the deny list.
func (p *Pipeline) refusedHosts(ctx context.Context) (map[string]bool, error) {
	sites, err := doclinks.SiteHosts(ctx, p.DB)
	if err != nil {
		return nil, fmt.Errorf("media: %w", err)
	}
	hosts := append([]string{}, SyncedHosts...)
	for h := range sites {
		hosts = append(hosts, h)
	}
	return NormalizeHostSet(append(hosts, p.DenyHosts...)), nil
}

// run is one pass's state.
type run struct {
	p      *Pipeline
	dir    string
	st     *Stats
	web    webGetter
	ext    *extract.Extractor
	ig     digest.ImageGenerator
	vision bool
	files  []string // the current item's temp files
}

// outcome is what working one item produced: a result to store, a failed
// attempt, or neither (the row waits as it is).
type outcome struct {
	res    *db.MediaResult
	fail   error
	usage  *digest.Usage
	copied bool
}

func failed(err error) outcome { return outcome{fail: err} }

func terminal(status, class string) outcome {
	return outcome{res: &db.MediaResult{Status: status, ErrorClass: class}}
}

// item works one row and stores its result.
func (r *run) item(ctx context.Context, it db.MediaItem) {
	o := r.work(ctx, it)
	if o.usage != nil {
		r.st.InTok += o.usage.InputTokens
		r.st.OutTok += o.usage.OutputTokens
		r.st.Cost += o.usage.CostUSD
	}
	if o.fail != nil {
		if ctx.Err() != nil {
			return // shutdown: no attempt is spent
		}
		r.fail(ctx, it, o.fail)
		return
	}
	if o.res == nil {
		return
	}
	// The parent's document is computed now, never reused: a Slack message
	// that gained replies renders into its thread document since.
	src, ref, err := kb.MediaParentRef(ctx, r.p.DB, it)
	if err != nil {
		r.fail(ctx, it, err)
		return
	}
	o.res.KBSource, o.res.KBRef = src, ref
	if err := r.p.DB.FinishMedia(ctx, it.ID, *o.res); err != nil {
		r.p.logf("media: item %d: %v", it.ID, err)
		return
	}
	switch o.res.Status {
	case "ok":
		if o.copied {
			r.st.Copied++
		} else {
			r.st.Described++
		}
		r.afterDescribed(ctx, it, *o.res)
	case "unavailable":
		r.st.Unavailable++
	default:
		r.st.Skipped++
	}
}

func (r *run) fail(ctx context.Context, it db.MediaItem, err error) {
	class := ClassifyError(err)
	r.st.Failed++
	r.p.logf("media: item %d (%s %s) failed (%s): %s", it.ID, it.ParentKind, it.Kind, class, redactURLs(err.Error()))
	if _, err := r.p.DB.FailMedia(ctx, it.ID, class, maxMediaAttempts); err != nil {
		r.p.logf("media: item %d: %v", it.ID, err)
	}
}

func (r *run) afterDescribed(ctx context.Context, it db.MediaItem, res db.MediaResult) {
	it.Status, it.Title, it.Body, it.ImageText, it.Keys = res.Status, res.Title, res.Body, res.ImageText, res.Keys
	it.KBSource, it.KBRef, it.Error = res.KBSource, res.KBRef, ""
	if res.Kind != "" {
		it.Kind = res.Kind
	}
	if res.ContentKey != "" {
		it.ContentKey = res.ContentKey
	}
	for _, hook := range r.p.AfterDescribed {
		if err := hook(ctx, it); err != nil {
			r.p.logf("media: item %d: after-described hook: %s", it.ID, redactURLs(err.Error()))
		}
	}
}

// work runs one item; a panic is a failed attempt, and the item's temp
// files are removed on every path before its result is written.
func (r *run) work(ctx context.Context, it db.MediaItem) (o outcome) {
	r.files = r.files[:0]
	defer func() {
		for _, f := range r.files {
			_ = os.Remove(f)
		}
		r.files = r.files[:0]
	}()
	defer func() {
		if v := recover(); v != nil {
			o = failed(fmt.Errorf("panic: %v", v))
		}
	}()
	switch it.Kind {
	case "link":
		return r.link(ctx, it)
	case "image":
		return r.image(ctx, it)
	}
	return failed(fmt.Errorf("unknown media kind %q", it.Kind))
}

// copyFrom copies the description of an ok row with key in the item's
// scope (title, body, image text, keys only), reporting whether one exists.
func (r *run) copyFrom(ctx context.Context, it db.MediaItem, key string) (outcome, bool) {
	src, err := r.p.DB.FindDescribedMedia(ctx, key, it.Scope)
	if err != nil {
		return failed(err), true
	}
	if src == nil || src.ID == it.ID {
		return outcome{}, false
	}
	return outcome{copied: true, res: &db.MediaResult{
		Status: "ok", Title: src.Title, Body: src.Body, ImageText: src.ImageText, Keys: src.Keys,
	}}, true
}

// fetchOutcome maps a web fetch error: a refused, missing or unsupported
// page is unreachable, an oversized one too_large, anything else a failed
// attempt.
func fetchOutcome(err error) outcome {
	switch {
	case errors.Is(err, webfetch.ErrRefused), errors.Is(err, webfetch.ErrNotFound), errors.Is(err, webfetch.ErrUnsupported):
		return terminal("unreachable", ClassifyError(err))
	case errors.Is(err, webfetch.ErrTooLarge):
		return terminal("too_large", "too_large")
	}
	return failed(err)
}

// link summarizes one link: a copy of the same URL's summary in scope, else
// a fetch; an image answer is described as an image.
func (r *run) link(ctx context.Context, it db.MediaItem) outcome {
	if it.ContentKey != "" {
		if o, ok := r.copyFrom(ctx, it, it.ContentKey); ok {
			return o
		}
	}
	u := linkURL(it)
	resp, err := r.web.Get(ctx, u, maxMediaDownload)
	if err != nil {
		return fetchOutcome(err)
	}
	defer resp.Body.Close()
	if strings.HasPrefix(resp.MediaType, "image/") {
		if !r.vision {
			o := terminal("unavailable", "")
			o.res.Kind = "image"
			return o
		}
		o := r.describeBody(ctx, it, resp.Body)
		if o.res != nil {
			o.res.Kind = "image"
		}
		return o
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxPageBytes+1))
	if err != nil {
		return fetchOutcome(err)
	}
	if len(body) > maxPageBytes {
		return terminal("too_large", "too_large")
	}
	title, login := scanHTML(body)
	if login {
		return terminal("unreachable", "refused")
	}
	secs, status, err := r.ext.Extract(ctx, "text/html", "", bytes.NewReader(body))
	if err != nil {
		return failed(err)
	}
	if status != extract.StatusOK {
		return terminal("unreachable", "unsupported")
	}
	texts := make([]string, 0, len(secs))
	for _, s := range secs {
		texts = append(texts, s.Text)
	}
	text := strings.TrimSpace(strings.Join(texts, "\n"))
	if utf8.RuneCountInString(text) < minPageRunes {
		return terminal("unreachable", "unsupported")
	}
	s, usage, err := callModel(ctx, summaryTimeout, func(ctx context.Context) (Summary, *digest.Usage, error) {
		return SummarizeLink(ctx, r.p.Gen, r.p.Prompts, u, title, text)
	})
	if err != nil {
		return outcome{fail: err, usage: usage}
	}
	return outcome{usage: usage, res: &db.MediaResult{Status: "ok", Title: s.Title, Body: s.Body}}
}

func linkURL(it db.MediaItem) string {
	if it.FetchURL != "" {
		return it.FetchURL
	}
	return strings.TrimPrefix(it.Locator, "url:")
}

// scanHTML returns the page's <title> and whether it holds a password field
// (a login page: never summarized).
func scanHTML(body []byte) (title string, login bool) {
	z := html.NewTokenizer(bytes.NewReader(body))
	inTitle, haveTitle := false, false
	for {
		switch z.Next() {
		case html.ErrorToken:
			return title, login
		case html.StartTagToken, html.SelfClosingTagToken:
			name, hasAttr := z.TagName()
			switch string(name) {
			case "title":
				inTitle = !haveTitle
			case "input":
				for hasAttr {
					var k, v []byte
					k, v, hasAttr = z.TagAttr()
					if string(k) == "type" && strings.EqualFold(strings.TrimSpace(string(v)), "password") {
						login = true
					}
				}
			}
		case html.TextToken:
			if inTitle {
				title += string(z.Text())
			}
		case html.EndTagToken:
			if name, _ := z.TagName(); string(name) == "title" && inTitle {
				inTitle, haveTitle = false, true
			}
		case html.CommentToken, html.DoctypeToken:
		}
	}
}

// image describes one image: no vision means unavailable without opening;
// a reference resolves first; else its bytes are opened into a temp file.
func (r *run) image(ctx context.Context, it db.MediaItem) outcome {
	if !r.vision {
		return terminal("unavailable", "")
	}
	if res := r.p.Resolvers[it.ParentKind]; res != nil {
		target, err := res.Resolve(ctx, it)
		switch {
		case errors.Is(err, ErrGone):
			return terminal("unreachable", "not_found")
		case err != nil:
			return failed(err)
		case target != nil:
			switch target.Status {
			case "ok":
				return outcome{copied: true, res: &db.MediaResult{Status: "ok", Title: target.Title,
					Body: target.Body, ImageText: target.ImageText, Keys: target.Keys}}
			case "pending", "unavailable":
				return outcome{}
			}
			return terminal("unreachable", "not_found")
		}
	}
	dctx, cancel := context.WithTimeout(ctx, imageDownloadTimeout)
	defer cancel()
	var body io.ReadCloser
	if strings.HasPrefix(it.Locator, "url:") {
		resp, err := r.web.Get(dctx, linkURL(it), maxMediaDownload)
		if err != nil {
			return fetchOutcome(err)
		}
		if !strings.HasPrefix(resp.MediaType, "image/") {
			_ = resp.Body.Close()
			return terminal("unreachable", "unsupported")
		}
		body = resp.Body
	} else {
		op := r.p.Openers[it.ParentKind]
		if op == nil {
			return outcome{} // no opener wired for this source yet: wait
		}
		var err error
		body, _, err = op.Open(dctx, it, maxMediaDownload)
		switch {
		case errors.Is(err, ErrGone):
			return terminal("unreachable", "not_found")
		case errors.Is(err, ErrTooLarge):
			return terminal("too_large", "too_large")
		case err != nil:
			return failed(err)
		}
	}
	defer body.Close()
	return r.describeBody(ctx, it, body)
}

// describeBody spools body into a temp file (≤ maxMediaDownload), then
// copies a description of the same bytes in scope or prepares and
// describes the image.
func (r *run) describeBody(ctx context.Context, it db.MediaItem, body io.Reader) outcome {
	path, sum, size, err := r.spool(body)
	if errors.Is(err, ErrTooLarge) || errors.Is(err, webfetch.ErrTooLarge) {
		return terminal("too_large", "too_large")
	}
	if err != nil {
		return failed(err)
	}
	key := "sha256:" + sum
	if o, ok := r.copyFrom(ctx, it, key); ok {
		if o.res != nil {
			o.res.ContentKey = key
		}
		return o
	}
	send, mt, o := r.prepare(ctx, path, size)
	if o.res != nil || o.fail != nil {
		if o.res != nil {
			o.res.ContentKey = key
		}
		return o
	}
	d, usage, err := callModel(ctx, describeTimeout, func(ctx context.Context) (Description, *digest.Usage, error) {
		return DescribeImage(digest.WithWorkDir(ctx, r.dir), r.ig, r.p.Prompts, send, mt)
	})
	if err != nil {
		return outcome{fail: err, usage: usage}
	}
	return outcome{usage: usage, res: &db.MediaResult{Status: "ok", ContentKey: key,
		Title: d.Title, Body: d.Body, ImageText: d.Text, Keys: d.Keys}}
}

// spool copies body into a fresh temp file, hashing it; more than
// maxMediaDownload bytes is ErrTooLarge.
func (r *run) spool(body io.Reader) (path, sum string, size int64, err error) {
	f, err := newTempFile(r.dir, "*")
	if err != nil {
		return "", "", 0, err
	}
	r.files = append(r.files, f.Name())
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, h), io.LimitReader(body, maxMediaDownload+1))
	if cerr := f.Close(); err == nil && cerr != nil {
		err = openError{cerr}
	}
	if err != nil {
		return "", "", 0, err
	}
	if n > maxMediaDownload {
		return "", "", 0, ErrTooLarge
	}
	return f.Name(), hex.EncodeToString(h.Sum(nil)), n, nil
}

// prepare sniffs the spooled image and returns the file and type to send,
// or a terminal outcome: an unsupported type, junk, or too large even after
// a downscale. HEIC/TIFF are converted to JPEG first. A sips timeout is a
// failed attempt.
func (r *run) prepare(ctx context.Context, path string, size int64) (send, mediaType string, o outcome) {
	mt, w, h, err := sniffImage(path)
	if errors.Is(err, errBadHeader) || (err == nil && mt == "") {
		return "", "", terminal("skipped_type", "")
	}
	if err != nil {
		return "", "", failed(err)
	}
	if mt == typeHEIC || mt == typeTIFF {
		path, size, mt, w, h, o = r.convert(ctx, path, "skipped_type", "-s", "format", "jpeg")
		if o.res != nil || o.fail != nil {
			return "", "", o
		}
	}
	if isJunk(size, w, h) {
		return "", "", terminal("skipped_junk", "")
	}
	if !fitsModel(size, w, h) {
		if int64(w)*int64(h) > maxConvertPixels {
			return "", "", terminal("too_large", "too_large")
		}
		path, size, mt, w, h, o = r.convert(ctx, path, "too_large", "-s", "format", "jpeg", "-Z", fmt.Sprint(downscaleSide))
		if o.res != nil || o.fail != nil {
			return "", "", o
		}
		if !fitsModel(size, w, h) {
			return "", "", terminal("too_large", "too_large")
		}
	}
	return path, mt, outcome{}
}

// convert runs sips on path and sniffs its JPEG output; a failure other
// than a timeout or cancel ends the item with failStatus.
func (r *run) convert(ctx context.Context, path, failStatus string, args ...string) (string, int64, string, int, int, outcome) {
	out, err := runSips(ctx, path, args...)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
			return "", 0, "", 0, 0, failed(err)
		}
		return "", 0, "", 0, 0, terminal(failStatus, "convert_failed")
	}
	r.files = append(r.files, out)
	mt, w, h, err := sniffImage(out)
	if err != nil || mt != typeJPEG {
		return "", 0, "", 0, 0, terminal(failStatus, "convert_failed")
	}
	size, err := fileSize(out)
	if err != nil {
		return "", 0, "", 0, 0, failed(err)
	}
	return out, size, mt, w, h, outcome{}
}

// callModel runs one model call under its own deadline. A call that
// ignores the deadline is abandoned when it passes; a panic is an error.
// Every error is a modelError (its class still reads timeout or
// bad_output through the chain).
func callModel[T any](ctx context.Context, timeout time.Duration, fn func(context.Context) (T, *digest.Usage, error)) (T, *digest.Usage, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	type result struct {
		v   T
		u   *digest.Usage
		err error
	}
	ch := make(chan result, 1)
	go func() {
		defer func() {
			if v := recover(); v != nil {
				ch <- result{err: fmt.Errorf("panic: %v", v)}
			}
		}()
		v, u, err := fn(ctx)
		ch <- result{v, u, err}
	}()
	select {
	case res := <-ch:
		if res.err != nil {
			return res.v, res.u, modelError{res.err}
		}
		return res.v, res.u, nil
	case <-ctx.Done():
		var zero T
		return zero, nil, modelError{ctx.Err()}
	}
}
