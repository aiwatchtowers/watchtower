// Package diagnostics builds the privacy-safe summary printed by
// `watchtower diagnostics` (Report a Problem, DIAG-01).
package diagnostics

import (
	"regexp"
	"strings"
)

// statusCode matches an HTTP code only in a status form:
// `(status|http|status code)[ :=]*NNN` or `NNN <reason phrase>`. A bare
// number (an id, a count) never matches. Applied to the lower-cased message.
func statusCode(code, reason string) *regexp.Regexp {
	return regexp.MustCompile(`\b(?:status code|status|http)[ :=]*` + code + `\b|\b` + code + ` ` + reason)
}

var (
	status429 = statusCode("429", "too many")
	status401 = statusCode("401", "unauthorized")
	status403 = statusCode("403", "forbidden")
	status404 = statusCode("404", "not found")
)

// errorClasses is the fixed check order; the first match wins.
var errorClasses = []struct {
	class   string
	markers []string
	status  []*regexp.Regexp
}{
	{"cancelled", []string{"context canceled"}, nil},
	{"timeout", []string{"deadline exceeded", "timed out", "timeout"}, nil},
	{"rate_limit", []string{"rate limit", "too many requests"}, []*regexp.Regexp{status429}},
	{"quota", []string{"usage limit", "quota", "insufficient credit"}, nil},
	{"auth", []string{"invalid_auth", "token revoked", "unauthorized", "forbidden"}, []*regexp.Regexp{status401, status403}},
	{"not_found", []string{"not_found"}, []*regexp.Regexp{status404}},
	{"network", []string{"connection refused", "no such host", "network is unreachable", "connection reset"}, nil},
	{"parse", []string{"unmarshal", "invalid character", "unexpected end of json"}, nil},
}

// ErrorClass maps a stored error message to one of `cancelled`, `timeout`,
// `rate_limit`, `quota`, `auth`, `not_found`, `network`, `parse` or `other`.
// Only the class is ever printed, never the message (DIAG-01).
func ErrorClass(msg string) string {
	m := strings.ToLower(msg)
	for _, c := range errorClasses {
		for _, marker := range c.markers {
			if strings.Contains(m, marker) {
				return c.class
			}
		}
		for _, re := range c.status {
			if re.MatchString(m) {
				return c.class
			}
		}
	}
	return "other"
}
