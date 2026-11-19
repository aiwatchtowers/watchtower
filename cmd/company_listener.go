package cmd

import (
	"context"
	"crypto/rand"
	"errors"
	"io"
	"log"
	"net/http"
	"sync"

	"watchtower/internal/companybundle"
	"watchtower/internal/oauthpage"
)

// The company link's paths on the connect listener (spec §3): a link is
// http://127.0.0.1:18551/company/connect?b=<bundle>; a valid one answers 302
// to the clean /company/connected page, so a reload never resubmits it.
const (
	companyConnectPath   = "/company/connect"
	companyConnectedPath = "/company/connected"
)

// companyLinkEvent: a company link waits for the person's confirm in
// Watchtower. Bundle is the bundle's normalized wire form; nothing is stored
// and nothing reaches a vendor until the app confirms it.
type companyLinkEvent struct {
	Event  string `json:"event"`
	Flow   string `json:"flow"`
	Bundle string `json:"bundle"`
}

// pendingLink is one company link handed (or being handed) to the app.
// handed closes once the hand-over ended; taken says how (written before the
// close, read after it).
type pendingLink struct {
	flow, wire, company string
	handed              chan struct{}
	taken               bool
}

// pendingLinks holds the one company link that waits for its confirm. The
// same bundle again while it waits (a double click, a prefetch, a reload
// before the redirect) is the same link: no second event. Another bundle
// waits until the app dismisses the first (company_dismiss). It lives in the
// serve child's memory only: a restarted child starts with none.
type pendingLinks struct {
	mu  sync.Mutex
	cur *pendingLink
	// shown is the company the /company/connected page names: the newest
	// link the app took, kept after it is dismissed so a reload of the page
	// still reads right.
	shown string
}

type linkOffer int

const (
	linkFresh     linkOffer = iota // the caller hands it over, then settles it
	linkDuplicate                  // the same link waits: wait for its hand-over
	linkBusy                       // another link waits
)

// offer takes a link with wire (normalized) for company.
func (p *pendingLinks) offer(wire, company string) (*pendingLink, linkOffer) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cur != nil {
		if p.cur.wire == wire {
			return p.cur, linkDuplicate
		}
		return p.cur, linkBusy
	}
	p.cur = &pendingLink{flow: rand.Text(), wire: wire, company: company, handed: make(chan struct{})}
	return p.cur, linkFresh
}

// settle ends link's hand-over: a link the app did not take stops waiting.
func (p *pendingLinks) settle(link *pendingLink, taken bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	link.taken = taken
	if taken {
		p.shown = link.company
	} else if p.cur == link {
		p.cur = nil
	}
	close(link.handed)
}

// release ends the waiting link flow; another flow (already released, or
// never this listener's) is a no-op.
func (p *pendingLinks) release(flow string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cur != nil && p.cur.flow == flow {
		p.cur = nil
	}
}

func (p *pendingLinks) shownCompany() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.shown
}

// companyEmit hands an event to the serve loop (the only writer of stdout);
// false when it was not taken (the browser went away or serve is stopping).
type companyEmit func(ctx context.Context, ev companyLinkEvent) bool

// companyAnswer writes a page (or, for "", an empty body) and logs the
// request by its path and answer only — never the query, which carries the
// bundle's secrets (FILES-01).
type companyAnswer func(status int, page, note string)

// companyGuarded serves path with the Slack paths' guards: a Host other than
// host is 421, another method 405, both with no body; it never serves files.
func companyGuarded(host, path string, logger *log.Logger,
	serve func(w http.ResponseWriter, r *http.Request, answer companyAnswer)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		answer := func(status int, page, note string) {
			logger.Printf("%s %s: %d%s", r.Method, path, status, note)
			if page != "" {
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
			}
			w.WriteHeader(status)
			if page != "" {
				_, _ = io.WriteString(w, page)
			}
		}
		if r.Host != host {
			answer(http.StatusMisdirectedRequest, "", "")
			return
		}
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", http.MethodGet)
			answer(http.StatusMethodNotAllowed, "", "")
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		serve(w, r, answer)
	}
}

// companyConnectHandler serves GET /company/connect and GET
// /company/connected on the connect listener.
func companyConnectHandler(host string, emit companyEmit, pending *pendingLinks, logger *log.Logger) http.Handler {
	connect := companyGuarded(host, companyConnectPath, logger, func(w http.ResponseWriter, r *http.Request, answer companyAnswer) {
		serveCompanyConnect(w, r, answer, host, emit, pending)
	})
	connected := companyGuarded(host, companyConnectedPath, logger, func(_ http.ResponseWriter, _ *http.Request, answer companyAnswer) {
		company := pending.shownCompany()
		if company == "" {
			answer(http.StatusNotFound, "", "")
			return
		}
		answer(http.StatusOK, oauthpage.CompanyOpen(company), "")
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == companyConnectPath {
			connect(w, r)
			return
		}
		connected(w, r)
	})
}

func serveCompanyConnect(w http.ResponseWriter, r *http.Request, answer companyAnswer, host string,
	emit companyEmit, pending *pendingLinks) {
	b, err := parseCompanyLink(r)
	var wire string
	if err == nil {
		wire, err = companybundle.Encode(b)
	}
	if err != nil {
		reason := companybundle.RefusalDamaged
		var pe *companybundle.ParseError
		if errors.As(err, &pe) {
			reason = pe.Reason
		}
		answer(http.StatusBadRequest, oauthpage.CompanyRefused(reason), " (refused: "+string(reason)+")")
		return
	}
	link, offered := pending.offer(wire, b.Company)
	switch offered {
	case linkBusy:
		answer(http.StatusConflict, oauthpage.CompanyBusy(), " (another link waits)")
		return
	case linkFresh:
		pending.settle(link, emit(r.Context(), companyLinkEvent{Event: "company_link", Flow: link.flow, Bundle: wire}))
	case linkDuplicate:
		select {
		case <-link.handed:
		case <-r.Context().Done():
			return
		}
	}
	if !link.taken {
		answer(http.StatusServiceUnavailable, oauthpage.CompanyNotTaken(), " (not taken)")
		return
	}
	w.Header().Set("Location", "http://"+host+companyConnectedPath)
	answer(http.StatusFound, "", "")
}

// parseCompanyLink reads the link's one b parameter as a link bundle.
func parseCompanyLink(r *http.Request) (companybundle.Bundle, error) {
	values := r.URL.Query()["b"]
	if len(values) != 1 {
		return companybundle.Bundle{}, errors.New("the link carries no single bundle")
	}
	return companybundle.Parse(values[0], companybundle.OriginLink)
}

// withCompanyPaths routes the company paths to company and everything else
// to the Slack listener's handler.
func withCompanyPaths(slack, company http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == companyConnectPath || r.URL.Path == companyConnectedPath {
			company.ServeHTTP(w, r)
			return
		}
		slack.ServeHTTP(w, r)
	})
}
