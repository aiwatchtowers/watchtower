package auth

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func hitTestCallback(t *testing.T, h http.HandlerFunc, params map[string]string) (int, string) {
	t.Helper()
	q := url.Values{}
	for k, v := range params {
		q.Set(k, v)
	}
	rec := httptest.NewRecorder()
	h(rec, httptest.NewRequest(http.MethodGet, "/callback?"+q.Encode(), nil))
	return rec.Code, rec.Body.String()
}

// A request with the wrong (or no) state — with or without an `error` — is
// refused and ignored: it neither ends the login nor uses up the delivery, so
// the real redirect that follows still gets through.
func TestCallbackHandler_WrongStateIsIgnored(t *testing.T) {
	h, ch := NewCallbackHandler("good-state", "OK PAGE", "ERR {{ERROR}}")

	for _, params := range []map[string]string{
		{"error": "access_denied"},
		{"error": "access_denied", "state": "bad-state"},
		{"code": "stolen", "state": "bad-state"},
		{"code": "stolen"},
	} {
		status, body := hitTestCallback(t, h, params)
		if status != http.StatusBadRequest {
			t.Errorf("params %v: status = %d, want 400", params, status)
		}
		if !strings.Contains(body, "This sign-in page is out of date") || !strings.Contains(body, "<!DOCTYPE html>") {
			t.Errorf("params %v: body = %q, want the out-of-date page", params, body)
		}
	}
	select {
	case res := <-ch:
		t.Fatalf("a wrong-state request delivered %+v", res)
	default:
	}

	status, body := hitTestCallback(t, h, map[string]string{"code": "real-code", "state": "good-state"})
	if status != http.StatusOK || body != "OK PAGE" {
		t.Fatalf("matching callback = %d %q, want 200 with the success page", status, body)
	}
	if res := <-ch; res.Code != "real-code" || res.Err != "" {
		t.Errorf("delivered %+v, want the real code", res)
	}
}

// Only the first matching request delivers; later ones get a bare 410 and
// never block on the channel nobody reads any more.
func TestCallbackHandler_FirstMatchingRequestWins(t *testing.T) {
	h, ch := NewCallbackHandler("s", "OK", "ERR {{ERROR}}")

	status, body := hitTestCallback(t, h, map[string]string{"error": "<denied>", "state": "s"})
	if status != http.StatusOK || !strings.Contains(body, "&lt;denied&gt;") {
		t.Fatalf("error callback = %d %q, want 200 with the escaped error page", status, body)
	}
	for range 3 {
		status, body = hitTestCallback(t, h, map[string]string{"code": "c", "state": "s"})
		if status != http.StatusGone || body != "" {
			t.Errorf("later callback = %d %q, want a bare 410", status, body)
		}
	}
	if res := <-ch; res.Err != "<denied>" || res.Code != "" {
		t.Errorf("delivered %+v, want the provider error", res)
	}
	select {
	case res := <-ch:
		t.Fatalf("a second delivery %+v", res)
	default:
	}
}
