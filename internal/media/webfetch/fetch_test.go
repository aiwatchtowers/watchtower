package webfetch_test

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"

	"watchtower/internal/media"
	"watchtower/internal/media/webfetch"
)

func allowAll(string) bool { return true }

// fakeResolver answers every A query with ip and every other query with no
// records, in memory: no test ever reaches a real DNS server. It counts the
// lookups it served.
func fakeResolver(t *testing.T, ip string) (*net.Resolver, *atomic.Int32) {
	t.Helper()
	var n atomic.Int32
	a := net.ParseIP(ip).To4()
	if a == nil {
		t.Fatalf("fakeResolver needs an IPv4 address, got %q", ip)
	}
	r := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
			client, server := net.Pipe()
			go serveDNS(server, [4]byte(a), &n)
			return client, nil
		},
	}
	return r, &n
}

// serveDNS answers stream-framed (2-byte length) queries on c until it closes.
func serveDNS(c net.Conn, a [4]byte, n *atomic.Int32) {
	defer func() { _ = c.Close() }()
	for {
		var l [2]byte
		if _, err := io.ReadFull(c, l[:]); err != nil {
			return
		}
		msg := make([]byte, binary.BigEndian.Uint16(l[:]))
		if _, err := io.ReadFull(c, msg); err != nil {
			return
		}
		var p dnsmessage.Parser
		h, err := p.Start(msg)
		if err != nil {
			return
		}
		q, err := p.Question()
		if err != nil {
			return
		}
		n.Add(1)
		b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: h.ID, Response: true, Authoritative: true, RecursionAvailable: true})
		b.EnableCompression()
		_ = b.StartQuestions()
		_ = b.Question(q)
		_ = b.StartAnswers()
		if q.Type == dnsmessage.TypeA {
			_ = b.AResource(dnsmessage.ResourceHeader{Name: q.Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 60}, dnsmessage.AResource{A: a})
		}
		out, err := b.Finish()
		if err != nil {
			return
		}
		binary.BigEndian.PutUint16(l[:], uint16(len(out)))
		if _, err := c.Write(append(l[:], out...)); err != nil {
			return
		}
	}
}

// counting wraps h and counts its hits.
func counting(h http.HandlerFunc) (http.HandlerFunc, *atomic.Int32) {
	var n atomic.Int32
	return func(w http.ResponseWriter, r *http.Request) {
		n.Add(1)
		h(w, r)
	}, &n
}

func html(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = io.WriteString(w, "<html><title>ok</title></html>")
}

func get(t *testing.T, f *webfetch.Fetcher, u string) (*webfetch.Response, error) {
	t.Helper()
	resp, err := f.Get(context.Background(), u, 0)
	if err == nil {
		t.Cleanup(func() { _ = resp.Body.Close() })
	}
	return resp, err
}

func TestGet_OK(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(html))
	defer srv.Close()
	resp, err := get(t, webfetch.NewForTest(allowAll), srv.URL+"/page")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil || !strings.Contains(string(body), "<title>ok</title>") {
		t.Fatalf("body %q, err %v", body, err)
	}
	if resp.MediaType != "text/html" || resp.FinalURL != srv.URL+"/page" {
		t.Errorf("MediaType %q FinalURL %q", resp.MediaType, resp.FinalURL)
	}
}

func TestGet_NilCheckRefusesEverything(t *testing.T) {
	h, hits := counting(html)
	srv := httptest.NewServer(h)
	defer srv.Close()
	if _, err := get(t, webfetch.NewForTest(nil), srv.URL); !errors.Is(err, webfetch.ErrRefused) {
		t.Fatalf("err = %v, want ErrRefused", err)
	}
	if _, err := get(t, &webfetch.Fetcher{}, srv.URL); !errors.Is(err, webfetch.ErrRefused) {
		t.Fatalf("zero Fetcher: err = %v, want ErrRefused", err)
	}
	if hits.Load() != 0 {
		t.Errorf("handler hit %d times", hits.Load())
	}
}

func TestGet_RefusesLoopbackServer(t *testing.T) {
	h, hits := counting(html)
	srv := httptest.NewServer(h)
	defer srv.Close()
	_, err := get(t, webfetch.New(allowAll), srv.URL)
	if !errors.Is(err, webfetch.ErrRefused) {
		t.Fatalf("err = %v, want ErrRefused", err)
	}
	if hits.Load() != 0 {
		t.Errorf("handler hit %d times", hits.Load())
	}
}

func TestGet_RefusesNameResolvingToLoopback(t *testing.T) {
	res, lookups := fakeResolver(t, "127.0.0.1")
	f := webfetch.New(allowAll)
	f.Resolver = res
	for _, u := range []string{"http://rebind.example/", "https://rebind.example/"} {
		_, err := get(t, f, u)
		if !errors.Is(err, webfetch.ErrRefused) {
			t.Errorf("%s: err = %v, want ErrRefused", u, err)
		}
	}
	if lookups.Load() == 0 {
		t.Error("the fake resolver was never asked: the refusal did not come from the connect-time check")
	}
}

func TestGet_RefusesRedirectToPrivate(t *testing.T) {
	target, targetHits := counting(html)
	private := httptest.NewServer(target)
	defer private.Close()
	for _, loc := range []string{private.URL + "/", "http://127.0.0.1/", "http://[::1]/", "http://169.254.169.254/latest/meta-data/"} {
		start := httptest.NewServer(http.RedirectHandler(loc, http.StatusFound))
		_, err := get(t, webfetch.NewForTest(allowAll), start.URL)
		start.Close()
		if !errors.Is(err, webfetch.ErrRefused) {
			t.Errorf("redirect to %s: err = %v, want ErrRefused", loc, err)
		}
	}
	if targetHits.Load() != 0 {
		t.Errorf("private target hit %d times", targetHits.Load())
	}
}

func TestGet_StopsAfterFiveRedirects(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := hits.Add(1)
		http.Redirect(w, r, "/hop"+strconv.Itoa(int(n)), http.StatusFound)
	}))
	defer srv.Close()
	_, err := get(t, webfetch.NewForTest(allowAll), srv.URL)
	if !errors.Is(err, webfetch.ErrRefused) {
		t.Fatalf("err = %v, want ErrRefused", err)
	}
	if got := hits.Load(); got != 6 {
		t.Errorf("server hit %d times, want 6 (the first request and five redirects)", got)
	}

	// Five redirects are followed.
	var n atomic.Int32
	ok := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if n.Add(1) <= 5 {
			http.Redirect(w, r, "/next", http.StatusFound)
			return
		}
		html(w, r)
	}))
	defer ok.Close()
	if _, err := get(t, webfetch.NewForTest(allowAll), ok.URL); err != nil {
		t.Errorf("five redirects: err = %v, want nil", err)
	}
}

func TestGet_RedirectRerunsCheck(t *testing.T) {
	refused := media.NormalizeHostSet([]string{"denied.example"})
	rows := []string{
		"https://example.com/?token=x",
		"https://example.com/reset/abc",
		"https://u:p@example.com/",
		"https://acme.atlassian.net/wiki/x",
		"https://denied.example/page",
		"https://docs.denied.example/page",
		"https://example.com:8443/",
		"ftp://example.com/",
		"http://127.0.0.1/",
	}
	for _, loc := range rows {
		t.Run(loc, func(t *testing.T) {
			start := httptest.NewServer(http.RedirectHandler(loc, http.StatusFound))
			defer start.Close()
			res, lookups := fakeResolver(t, "127.0.0.1")
			f := webfetch.NewForTest(fetchableExcept(start.URL, refused))
			f.Resolver = res
			_, err := get(t, f, start.URL)
			if !errors.Is(err, webfetch.ErrRefused) {
				t.Fatalf("err = %v, want ErrRefused", err)
			}
			if lookups.Load() != 0 {
				t.Errorf("the target was resolved (%d lookups): Check did not stop the hop", lookups.Load())
			}
		})
	}

	// Control row: a target Fetchable accepts passes Check and reaches the
	// dial (resolved, then refused at connect time as a loopback address).
	start := httptest.NewServer(http.RedirectHandler("https://example.com/ok", http.StatusFound))
	defer start.Close()
	res, lookups := fakeResolver(t, "127.0.0.1")
	f := webfetch.NewForTest(fetchableExcept(start.URL, refused))
	f.Resolver = res
	if _, err := get(t, f, start.URL); !errors.Is(err, webfetch.ErrRefused) {
		t.Fatalf("control row: err = %v, want ErrRefused", err)
	}
	if lookups.Load() == 0 {
		t.Error("control row: the accepted target was never resolved")
	}
}

// fetchableExcept is media.Fetchable over refused as the Check hook, with the
// one httptest start URL exempt (Fetchable refuses IP-literal hosts and
// non-web ports, so the local first hop could not start otherwise).
func fetchableExcept(start string, refused map[string]bool) func(string) bool {
	return func(u string) bool {
		if u == start {
			return true
		}
		_, ok := media.Fetchable(u, refused)
		return ok
	}
}

func TestGet_RefusesNonWebPort(t *testing.T) {
	res, lookups := fakeResolver(t, "93.184.215.14")
	f := webfetch.New(func(u string) bool { _, ok := media.Fetchable(u, nil); return ok })
	f.Resolver = res
	if _, err := get(t, f, "http://example.com:6379/"); !errors.Is(err, webfetch.ErrRefused) {
		t.Fatalf("err = %v, want ErrRefused", err)
	}
	if lookups.Load() != 0 {
		t.Error("a refused URL was resolved")
	}

	// The connect-time check refuses non-web ports on its own.
	prod := webfetch.New(allowAll)
	for _, addr := range []string{"93.184.215.14:22", "93.184.215.14:6379", "[2606:2800::1]:8080", "93.184.215.14:0"} {
		if err := prod.ControlForTest("tcp4", addr); !errors.Is(err, webfetch.ErrRefused) {
			t.Errorf("Control(%s) = %v, want ErrRefused", addr, err)
		}
	}
	for _, addr := range []string{"93.184.215.14:80", "93.184.215.14:443", "[2606:2800::1]:443"} {
		if err := prod.ControlForTest("tcp", addr); err != nil {
			t.Errorf("Control(%s) = %v, want nil", addr, err)
		}
	}
	for _, addr := range []string{"127.0.0.1:443", "[::ffff:10.0.0.1]:80", "[64:ff9b::7f00:1]:443", "bogus", "93.184.215.14"} {
		if err := prod.ControlForTest("tcp", addr); !errors.Is(err, webfetch.ErrRefused) {
			t.Errorf("Control(%s) = %v, want ErrRefused", addr, err)
		}
	}
	if err := prod.ControlForTest("udp", "93.184.215.14:443"); !errors.Is(err, webfetch.ErrRefused) {
		t.Errorf("Control(udp) = %v, want ErrRefused", err)
	}
}

func TestGet_IgnoresEnvProxy(t *testing.T) {
	// The transport's Proxy field is the real check: with it nil, no
	// environment variable can route a fetch through a proxy. (An end-to-end
	// probe cannot tell: Go never proxies loopback targets, and a proxy dial
	// would itself be refused by the connect-time gate.)
	for _, k := range []string{"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"} {
		t.Setenv(k, "http://proxy.example:8080")
	}
	if webfetch.New(allowAll).TransportForTest().Proxy != nil {
		t.Fatal("Transport.Proxy is set")
	}
}

// recorder records each request's headers in order.
type recorder struct {
	mu   sync.Mutex
	seen []http.Header
}

func (r *recorder) add(h http.Header) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.seen = append(r.seen, h.Clone())
}

func twoHopServer(t *testing.T, rec *recorder) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec.add(r.Header)
		if r.URL.Path == "/" {
			http.SetCookie(w, &http.Cookie{Name: "sid", Value: "secret", Path: "/"})
			w.Header().Set("WWW-Authenticate", `Basic realm="x"`)
			http.Redirect(w, r, "/second", http.StatusFound)
			return
		}
		html(w, r)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestGet_SendsNoCookiesOrAuth(t *testing.T) {
	rec := &recorder{}
	srv := twoHopServer(t, rec)
	if _, err := get(t, webfetch.NewForTest(allowAll), srv.URL+"/"); err != nil {
		t.Fatalf("Get: %v", err)
	}
	if len(rec.seen) != 2 {
		t.Fatalf("%d hops, want 2", len(rec.seen))
	}
	for i, h := range rec.seen {
		if h.Get("Cookie") != "" || h.Get("Authorization") != "" {
			t.Errorf("hop %d sent Cookie %q Authorization %q", i+1, h.Get("Cookie"), h.Get("Authorization"))
		}
	}

	// Userinfo is refused by the fetcher itself, whatever Check says: Go
	// would send it as Authorization: Basic on that request.
	var hops recorder
	var srvURL string
	ui := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hops.add(r.Header)
		if r.URL.Path == "/" {
			http.Redirect(w, r, strings.Replace(srvURL, "http://", "http://u:p@", 1)+"/second", http.StatusFound)
			return
		}
		html(w, r)
	}))
	defer ui.Close()
	srvURL = ui.URL
	if _, err := get(t, webfetch.NewForTest(allowAll), ui.URL+"/"); !errors.Is(err, webfetch.ErrRefused) {
		t.Errorf("redirect to userinfo: err = %v, want ErrRefused", err)
	}
	if _, err := get(t, webfetch.NewForTest(allowAll), strings.Replace(ui.URL, "http://", "http://u:p@", 1)+"/second"); !errors.Is(err, webfetch.ErrRefused) {
		t.Errorf("initial userinfo: err = %v, want ErrRefused", err)
	}
	if len(hops.seen) != 1 {
		t.Errorf("%d requests reached the server, want 1 (the redirecting hop)", len(hops.seen))
	}
	for i, h := range hops.seen {
		if h.Get("Authorization") != "" {
			t.Errorf("request %d sent Authorization %q", i+1, h.Get("Authorization"))
		}
	}
}

func TestGet_OwnAddressFailureFailsClosed(t *testing.T) {
	restore := webfetch.FailInterfaceAddrsForTest(errors.New("no interfaces"))
	defer restore()
	err := webfetch.New(allowAll).ControlForTest("tcp", "93.184.215.14:443")
	if !errors.Is(err, webfetch.ErrRefused) || !strings.Contains(err.Error(), "own addresses: no interfaces") {
		t.Fatalf("err = %v, want ErrRefused explaining the own-address failure", err)
	}
}

func TestGet_HeadersExact(t *testing.T) {
	if strings.Contains(strings.ToLower(webfetch.UserAgent), "watchtower") {
		t.Fatalf("UserAgent names the product: %q", webfetch.UserAgent)
	}
	if webfetch.UserAgent != "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36" {
		t.Errorf("UserAgent = %q", webfetch.UserAgent)
	}
	if webfetch.Accept != "text/html,application/xhtml+xml,image/*;q=0.8" {
		t.Errorf("Accept = %q", webfetch.Accept)
	}
	rec := &recorder{}
	srv := twoHopServer(t, rec)
	if _, err := get(t, webfetch.NewForTest(allowAll), srv.URL+"/"); err != nil {
		t.Fatalf("Get: %v", err)
	}
	if len(rec.seen) != 2 {
		t.Fatalf("%d hops, want 2", len(rec.seen))
	}
	want := http.Header{"User-Agent": {webfetch.UserAgent}, "Accept": {webfetch.Accept}}
	for i, h := range rec.seen {
		if len(h) != len(want) {
			t.Errorf("hop %d headers %v, want exactly %v", i+1, h, want)
		}
		for k, v := range want {
			if got := h.Values(k); len(got) != 1 || got[0] != v[0] {
				t.Errorf("hop %d %s = %q, want %q", i+1, k, got, v[0])
			}
		}
		if h.Get("Referer") != "" {
			t.Errorf("hop %d sent Referer %q", i+1, h.Get("Referer"))
		}
	}
}

func TestGet_CapsBodyAndTime(t *testing.T) {
	big := strings.Repeat("a", 3<<20)
	for name, h := range map[string]http.HandlerFunc{
		"content-length": func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "text/html")
			w.Header().Set("Content-Length", strconv.Itoa(len(big)))
			_, _ = io.WriteString(w, big)
		},
		"chunked": func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "text/html")
			w.(http.Flusher).Flush()
			_, _ = io.WriteString(w, big)
		},
	} {
		t.Run(name, func(t *testing.T) {
			srv := httptest.NewServer(h)
			defer srv.Close()
			resp, err := webfetch.NewForTest(allowAll).Get(context.Background(), srv.URL, 0)
			if err == nil {
				var n int64
				n, err = io.Copy(io.Discard, resp.Body)
				_ = resp.Body.Close() // before srv.Close, which waits for the blocked handler
				if n > 2<<20 {
					t.Errorf("read %d bytes past the 2 MiB cap", n)
				}
			}
			if !errors.Is(err, webfetch.ErrTooLarge) {
				t.Fatalf("err = %v, want ErrTooLarge", err)
			}
		})
	}

	// The per-call cap overrides the default.
	srv := httptest.NewServer(http.HandlerFunc(html))
	defer srv.Close()
	resp, err := webfetch.NewForTest(allowAll).Get(context.Background(), srv.URL, 10)
	if err == nil {
		_, err = io.ReadAll(resp.Body)
		_ = resp.Body.Close()
	}
	if !errors.Is(err, webfetch.ErrTooLarge) {
		t.Errorf("10-byte cap: err = %v, want ErrTooLarge", err)
	}

	trickle := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		for {
			_, _ = io.WriteString(w, "a")
			w.(http.Flusher).Flush()
			select {
			case <-r.Context().Done():
				return
			case <-time.After(50 * time.Millisecond):
			}
		}
	}))
	defer trickle.Close()
	f := webfetch.NewForTest(allowAll)
	f.Timeout = 300 * time.Millisecond
	begin := time.Now()
	resp, err = f.Get(context.Background(), trickle.URL, 0)
	if err == nil {
		_, err = io.ReadAll(resp.Body)
		_ = resp.Body.Close()
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("trickle: err = %v, want a deadline error", err)
	}
	if el := time.Since(begin); el > f.Timeout+time.Second {
		t.Errorf("trickle took %v, want within %v", el, f.Timeout+time.Second)
	}
}

func TestGet_StatusAndType(t *testing.T) {
	cases := map[string]struct {
		h    http.HandlerFunc
		want error
	}{
		"no type": {func(w http.ResponseWriter, _ *http.Request) {
			w.Header()["Content-Type"] = nil
			_, _ = w.Write([]byte{0, 1, 2})
		}, webfetch.ErrUnsupported},
		"gzip": {func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "text/html")
			w.Header().Set("Content-Encoding", "gzip")
			_, _ = w.Write([]byte{0x1f, 0x8b, 0, 0})
		}, webfetch.ErrUnsupported},
		"br": {func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "image/png")
			w.Header().Set("Content-Encoding", "br")
			_, _ = io.WriteString(w, "x")
		}, webfetch.ErrUnsupported},
		"404": {func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) }, webfetch.ErrNotFound},
		"500": {func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusInternalServerError) }, webfetch.ErrNotFound},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			srv := httptest.NewServer(c.h)
			defer srv.Close()
			if _, err := get(t, webfetch.NewForTest(allowAll), srv.URL); !errors.Is(err, c.want) {
				t.Fatalf("err = %v, want %v", err, c.want)
			}
		})
	}
	for _, ct := range []string{"image/png", "application/xhtml+xml; charset=utf-8", "TEXT/HTML"} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", ct)
			w.Header().Set("Content-Encoding", "identity")
			_, _ = io.WriteString(w, "x")
		}))
		resp, err := get(t, webfetch.NewForTest(allowAll), srv.URL)
		srv.Close()
		if err != nil {
			t.Errorf("%s: err = %v", ct, err)
			continue
		}
		if want := strings.ToLower(strings.SplitN(ct, ";", 2)[0]); resp.MediaType != want {
			t.Errorf("%s: MediaType %q, want %q", ct, resp.MediaType, want)
		}
	}
}

func TestGet_RejectsUnsupportedType(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/pdf")
		_, _ = io.WriteString(w, "%PDF-1.4")
	}))
	defer srv.Close()
	if _, err := get(t, webfetch.NewForTest(allowAll), srv.URL); !errors.Is(err, webfetch.ErrUnsupported) {
		t.Fatalf("err = %v, want ErrUnsupported", err)
	}
}

func TestGet_RefusesNonWebScheme(t *testing.T) {
	for _, u := range []string{"ftp://example.com/", "file:///etc/passwd", "gopher://example.com/", "javascript:alert(1)"} {
		if _, err := get(t, webfetch.NewForTest(allowAll), u); !errors.Is(err, webfetch.ErrRefused) {
			t.Errorf("%s: err = %v, want ErrRefused", u, err)
		}
	}
}
