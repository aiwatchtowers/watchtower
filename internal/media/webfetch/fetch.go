// Package webfetch fetches a public web page or image for the media pass,
// anonymously and only from public addresses. A message must never steer it
// into the owner's machine or network: the connected address is checked at
// connect time (no DNS-rebinding window), every redirect hop re-runs the
// caller's URL rules, and no cookie, credential, Referer, proxy or product
// User-Agent ever leaves with a request.
package webfetch

import (
	"context"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"sync"
	"syscall"
	"time"
)

// The exact request headers: a generic browser, no product name.
const (
	UserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
	Accept    = "text/html,application/xhtml+xml,image/*;q=0.8"
)

// Defaults of New.
const (
	defaultTimeout  = 15 * time.Second
	defaultMaxBytes = 2 << 20
	maxRedirects    = 5
)

// dialTimeout bounds one connection attempt (a var so tests can shrink it).
var dialTimeout = 5 * time.Second

var (
	// ErrRefused: the scheme, the address, the redirect count or a
	// redirect target is not allowed.
	ErrRefused = errors.New("webfetch: refused")
	// ErrTooLarge: the body is longer than the cap.
	ErrTooLarge = errors.New("webfetch: body too large")
	// ErrNotFound: the server answered with a non-2xx status.
	ErrNotFound = errors.New("webfetch: not found")
	// ErrUnsupported: the content type is not HTML, XHTML or an image.
	ErrUnsupported = errors.New("webfetch: unsupported content type")
)

// Fetcher fetches public URLs. Check is required: it is run on the initial
// URL and on every redirect hop, and a nil Check refuses everything. Use New;
// a Fetcher must not be copied after first use.
type Fetcher struct {
	Resolver *net.Resolver // nil = the system resolver
	Timeout  time.Duration // whole fetch, body included; 0 = defaultTimeout
	MaxBytes int64         // body cap when Get's maxBytes is 0; 0 = defaultMaxBytes
	Check    func(rawURL string) bool

	// allowPrivateForTest lets the dial to the initial URL's literal
	// host:port (an httptest server) through; set only by tests.
	allowPrivateForTest bool

	ownOnce sync.Once
	own     []netip.Addr
	ownErr  error
}

// New is a Fetcher with the 15 s timeout and the 2 MiB HTML cap.
func New(check func(string) bool) *Fetcher {
	return &Fetcher{Timeout: defaultTimeout, MaxBytes: defaultMaxBytes, Check: check}
}

// Response is a successful fetch. The caller must close Body; reading past
// the cap fails with ErrTooLarge, and the fetch's deadline covers the reads.
type Response struct {
	FinalURL  string
	MediaType string // lowercased, without parameters
	Body      io.ReadCloser
}

// Get fetches rawURL. maxBytes caps the body (0 = the Fetcher's MaxBytes).
// Errors wrap ErrRefused, ErrTooLarge, ErrNotFound, ErrUnsupported or the
// network/deadline error; none carries the URL.
func (f *Fetcher) Get(ctx context.Context, rawURL string, maxBytes int64) (*Response, error) {
	if f.Check == nil || !f.Check(rawURL) {
		return nil, ErrRefused
	}
	u, err := url.Parse(rawURL)
	if err != nil || !webScheme(u.Scheme) || u.User != nil {
		return nil, ErrRefused // userinfo would become an Authorization header
	}
	if maxBytes <= 0 {
		maxBytes = f.MaxBytes
	}
	if maxBytes <= 0 {
		maxBytes = defaultMaxBytes
	}
	timeout := f.Timeout
	if timeout <= 0 {
		timeout = defaultTimeout
	}
	testAllow := ""
	if f.allowPrivateForTest {
		testAllow = u.Host
	}

	ctx, cancel := context.WithTimeout(ctx, timeout)
	tr := f.transport(testAllow)
	cleanup := func() { tr.CloseIdleConnections(); cancel() }
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		cleanup()
		return nil, ErrRefused
	}
	req.Header = http.Header{"User-Agent": {UserAgent}, "Accept": {Accept}}
	client := &http.Client{Transport: tr, CheckRedirect: f.checkRedirect}
	resp, err := client.Do(req)
	if err != nil {
		cleanup()
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err // drop the URL from the error
		}
		return nil, err
	}
	fail := func(e error) (*Response, error) {
		_ = resp.Body.Close()
		cleanup()
		return nil, e
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return fail(fmt.Errorf("%w: status %d", ErrNotFound, resp.StatusCode))
	}
	mt, _, err := mime.ParseMediaType(resp.Header.Get("Content-Type"))
	mt = strings.ToLower(mt)
	if err != nil || !(mt == "text/html" || mt == "application/xhtml+xml" || strings.HasPrefix(mt, "image/")) {
		return fail(ErrUnsupported)
	}
	if ce := strings.TrimSpace(resp.Header.Get("Content-Encoding")); ce != "" && !strings.EqualFold(ce, "identity") {
		return fail(ErrUnsupported) // an encoding we never asked for
	}
	if resp.ContentLength > maxBytes {
		return fail(ErrTooLarge)
	}
	return &Response{
		FinalURL:  resp.Request.URL.String(),
		MediaType: mt,
		Body:      &cappedBody{r: io.LimitReader(resp.Body, maxBytes+1), left: maxBytes, c: resp.Body, done: cleanup},
	}, nil
}

func webScheme(s string) bool { return s == "http" || s == "https" }

// checkRedirect drops the Referer Go's client has just set, stops after five
// redirects, refuses userinfo (Go would send it as Authorization) and re-runs
// the scheme rule and Check on the hop's URL.
func (f *Fetcher) checkRedirect(req *http.Request, via []*http.Request) error {
	req.Header.Del("Referer")
	if len(via) > maxRedirects || !webScheme(req.URL.Scheme) || req.URL.User != nil || f.Check == nil || !f.Check(req.URL.String()) {
		return ErrRefused
	}
	return nil
}

// transport is a one-fetch transport: no proxy, no compression negotiation
// (so the headers stay exactly ours), every connection through control.
func (f *Fetcher) transport(testAllow string) *http.Transport {
	d := &net.Dialer{Timeout: dialTimeout, Resolver: f.Resolver, Control: f.control(testAllow)}
	return &http.Transport{
		Proxy:                  nil,
		DialContext:            d.DialContext,
		DisableCompression:     true,
		TLSHandshakeTimeout:    dialTimeout,
		MaxResponseHeaderBytes: 64 << 10,
	}
}

// control is the connect-time gate: it sees the address the socket is about
// to connect to (after DNS) and refuses anything but TCP to a public address
// on port 80 or 443. testAllow, when set, is the one literal host:port the
// test escape hatch lets through.
func (f *Fetcher) control(testAllow string) func(network, address string, _ syscall.RawConn) error {
	return func(network, address string, _ syscall.RawConn) error {
		if testAllow != "" && address == testAllow {
			return nil
		}
		if network != "tcp" && network != "tcp4" && network != "tcp6" {
			return ErrRefused
		}
		ap, err := netip.ParseAddrPort(address)
		if err != nil || (ap.Port() != 80 && ap.Port() != 443) {
			return ErrRefused
		}
		f.ownOnce.Do(func() { f.own, f.ownErr = ownAddrs() })
		if f.ownErr != nil {
			return fmt.Errorf("%w: own addresses: %v", ErrRefused, f.ownErr)
		}
		if !IsPublic(ap.Addr(), f.own) {
			return ErrRefused
		}
		return nil
	}
}

// cappedBody fails a read past the cap with ErrTooLarge and releases the
// fetch's transport and deadline on Close.
type cappedBody struct {
	r    io.Reader
	left int64
	c    io.Closer
	done func()
	once sync.Once
}

func (b *cappedBody) Read(p []byte) (int, error) {
	n, err := b.r.Read(p)
	if int64(n) > b.left {
		n = int(b.left)
		b.left = 0
		return n, ErrTooLarge
	}
	b.left -= int64(n)
	return n, err
}

func (b *cappedBody) Close() error {
	err := b.c.Close()
	b.once.Do(b.done)
	return err
}
