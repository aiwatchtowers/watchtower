package diagnostics

import "testing"

func TestErrorClass(t *testing.T) {
	cases := []struct {
		name, msg, want string
	}{
		{"cancelled", "context canceled", "cancelled"},
		{"timeout deadline", "Post https://api.example.com/v1: context deadline exceeded", "timeout"},
		{"timeout timed out", "read timed out", "timeout"},
		{"timeout word", "i/o timeout", "timeout"},
		{"rate limit http", "HTTP 429 Too Many Requests", "rate_limit"},
		{"rate limit words", "rate limit exceeded", "rate_limit"},
		{"rate limit status", "status 429", "rate_limit"},
		{"rate limit status code", "status code: 429", "rate_limit"},
		{"rate limit reason", "got 429 too many", "rate_limit"},
		{"rate limit slack", "slack: ratelimited", "rate_limit"},
		{"rate limit underscore", "rate_limited: retry later", "rate_limit"},
		{"rate limit hyphen", "request rate-limited", "rate_limit"},
		{"quota usage", "usage limit reached", "quota"},
		{"quota word", "Quota exceeded for project", "quota"},
		{"quota credit", "insufficient credit balance", "quota"},
		{"auth invalid", "invalid_auth", "auth"},
		{"auth revoked", "token revoked", "auth"},
		{"auth status 401", "status 401", "auth"},
		{"auth http 403", "http=403", "auth"},
		{"auth reason", "401 Unauthorized", "auth"},
		{"auth not_authed", "slack: not_authed", "auth"},
		{"auth token_expired", "slack: token_expired", "auth"},
		{"auth oauth2 grant", `oauth2: "invalid_grant" "Token has been expired or revoked."`, "auth"},
		{"auth claude api", `API Error: 401 {"type":"error","error":{"type":"authentication_error"}}`, "auth"},
		{"auth api key", "Invalid API key provided", "auth"},
		{"auth googleapi error status", "googleapi: Error 401: Request had invalid credentials", "auth"},
		{"auth googleapi 403", "googleapi: Error 403: Insufficient Permission", "auth"},
		{"not found googleapi", "googleapi: Error 404: Requested entity was not found", "not_found"},
		{"rate limit googleapi", "googleapi: Error 429: Resource has been exhausted", "rate_limit"},
		{"not found status", "status 404", "not_found"},
		{"not found reason", "404 Not Found", "not_found"},
		{"not found code", "slack: channel_not_found", "not_found"},
		{"network refused", "dial tcp: connection refused", "network"},
		{"network host", "dial tcp: lookup api.example.com: no such host", "network"},
		{"network unreachable", "connect: network is unreachable", "network"},
		{"network reset", "read: connection reset by peer", "network"},
		{"network no route", "dial tcp: connect: no route to host", "network"},
		{"network broken pipe", "write: broken pipe", "network"},
		{"network unexpected eof", "unexpected EOF", "network"},
		{"parse char", "invalid character 'x' looking for beginning of value", "parse"},
		{"parse unmarshal", "json: cannot unmarshal string into Go value", "parse"},
		{"parse eof", "unexpected end of JSON input", "parse"},
		{"other", "boom", "other"},
		{"empty", "", "other"},
		{"id-like 401 is not a status", "channel C401X failed", "other"},
		{"bare number is not a status", "sync 404 items failed", "other"},
		{"bare 429 is not a status", "fetched 429 messages then failed", "other"},
		{"longer number is not a status", "status 4291", "other"},
		{"error id-like is not a status", "error 4012 in batch", "other"},
		{"error prefix glued to word is not a status", "suberror 401x", "other"},
		{"order timeout before auth", "timed out after status 401", "timeout"},
		{"order cancelled before timeout", "context canceled while waiting: timeout", "cancelled"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := ErrorClass(c.msg); got != c.want {
				t.Errorf("ErrorClass(%q) = %q, want %q", c.msg, got, c.want)
			}
		})
	}
}
