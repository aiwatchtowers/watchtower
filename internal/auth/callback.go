package auth

import (
	"crypto/subtle"
	"fmt"
	"html"
	"net/http"
	"strings"
	"sync/atomic"
)

// CallbackResult is what the one accepted loopback OAuth callback carried:
// the authorization code, or the provider's `error` parameter.
type CallbackResult struct {
	Code string
	Err  string
}

// StateMatches reports whether a callback's state equals the one the login
// sent, in constant time.
func StateMatches(got, want string) bool {
	return subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

// NewCallbackHandler returns the handler for a loopback OAuth redirect and the
// channel its single result arrives on (buffered, so the send never blocks).
//
// A request whose state does not match is answered 400 and ignored: it neither
// ends the login nor uses up the delivery, so a stray local request (with or
// without an `error`) cannot derail a sign-in in progress. Providers echo the
// state on error redirects too (RFC 6749 §4.1.2.1), so a real denial still
// arrives. The first matching request delivers — the code, or the provider's
// error, which gets errorPage with its {{ERROR}} placeholder filled — and every
// later matching request gets a bare 410.
func NewCallbackHandler(state, successPage, errorPage string) (http.HandlerFunc, <-chan CallbackResult) {
	ch := make(chan CallbackResult, 1)
	var delivered atomic.Bool
	return func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if !StateMatches(q.Get("state"), state) {
			http.Error(w, "state mismatch", http.StatusBadRequest)
			return
		}
		if !delivered.CompareAndSwap(false, true) {
			w.WriteHeader(http.StatusGone)
			return
		}
		res := CallbackResult{Code: q.Get("code"), Err: q.Get("error")}
		select {
		case ch <- res:
		default:
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if res.Err != "" {
			// #nosec G705 -- the provider error is html.EscapeString-encoded
			// before interpolation; the taint analysis does not track it.
			fmt.Fprint(w, strings.Replace(errorPage, "{{ERROR}}", html.EscapeString(res.Err), 1)) //nolint:gosec
			return
		}
		fmt.Fprint(w, successPage)
	}, ch
}
