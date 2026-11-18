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

// pendingLinks holds the one company link that waits for its confirm. The
// same bundle again while it waits (a double click, a prefetch, a reload
// before the redirect) is the same link: no second event. Another bundle
// waits until the app dismisses the first (company_dismiss).
type pendingLinks struct {
	mu   sync.Mutex
	flow string
	wire string
	// shown is the company the /company/connected page names: the newest
	// link the app was asked about, kept after it is dismissed so a reload
	// of the page still reads right.
	shown string
}

type linkOffer int

const (
	linkFresh linkOffer = iota
	linkDuplicate
	linkBusy
)

// offer takes a link with wire (normalized) for company.
func (p *pendingLinks) offer(wire, company string) (string, linkOffer) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.flow != "" {
		if p.wire == wire {
			return p.flow, linkDuplicate
		}
		return p.flow, linkBusy
	}
	p.flow, p.wire, p.shown = rand.Text(), wire, company
	return p.flow, linkFresh
}

// release ends the waiting link flow; another flow (already released, or
// never this listener's) is a no-op.
func (p *pendingLinks) release(flow string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if flow != "" && p.flow == flow {
		p.flow, p.wire = "", ""
	}
}

func (p *pendingLinks) shownCompany() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.shown
}

// companyEmit hands an event to the serve loop (the only writer of stdout);
// false when it was not taken (the browser went away or serve is stopping).
type companyEmit func(ctx context.Context, ev any) bool

// companyConnectHandler serves GET /company/connect and GET
// /company/connected on the connect listener. The same guards as the Slack
// paths: a Host other than host is 421, another method 405, both with no
// body; it never serves files. The log names the path and the answer only —
// never the query, which carries the bundle's secrets (FILES-01).
func companyConnectHandler(host string, emit companyEmit, pending *pendingLinks, logger *log.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := companyConnectedPath
		if r.URL.Path == companyConnectPath {
			path = companyConnectPath
		}
		answer := func(status int, page, note string) {
			logger.Printf("%s %s: %d%s", r.Method, path, status, note)
			if page == "" {
				w.WriteHeader(status)
				return
			}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.WriteHeader(status)
			_, _ = io.WriteString(w, page)
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
		if path == companyConnectedPath {
			company := pending.shownCompany()
			if company == "" {
				answer(http.StatusNotFound, "", "")
				return
			}
			answer(http.StatusOK, oauthpage.CompanyOpen(company), "")
			return
		}

		b, err := parseCompanyLink(r)
		if err != nil {
			reason := companybundle.RefusalDamaged
			var pe *companybundle.ParseError
			if errors.As(err, &pe) {
				reason = pe.Reason
			}
			answer(http.StatusBadRequest, oauthpage.CompanyRefused(reason), " (refused: "+string(reason)+")")
			return
		}
		wire, err := companybundle.Encode(b)
		if err != nil {
			answer(http.StatusBadRequest, oauthpage.CompanyRefused(companybundle.RefusalTooLong), " (refused: re-encoding)")
			return
		}
		flow, offered := pending.offer(wire, b.Company)
		switch offered {
		case linkBusy:
			answer(http.StatusConflict, oauthpage.CompanyBusy(), " (another link waits)")
			return
		case linkFresh:
			if !emit(r.Context(), companyLinkEvent{Event: "company_link", Flow: flow, Bundle: wire}) {
				pending.release(flow)
				answer(http.StatusServiceUnavailable, oauthpage.Error(
					"Watchtower did not take this link. Open Watchtower, then open the link again.", false), "")
				return
			}
		case linkDuplicate:
		}
		w.Header().Set("Location", "http://"+host+companyConnectedPath)
		answer(http.StatusFound, "", "")
	})
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
