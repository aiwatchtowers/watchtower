// Package slackconnect is the PKCE loopback flow that connects a Slack
// workspace through a company's own Watchtower app: it parses the connect
// link or code, holds the one flow in progress, builds Slack's authorize URL,
// answers the loopback listener's two paths and exchanges the code without a
// client secret. It stores nothing — the account write is the caller's.
package slackconnect

import (
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

// Port is the loopback port the connect listener binds and the app's
// manifest registers in its redirect URL. It sits outside every other OAuth
// listener's range (TestOAuthPortRanges_Disjoint).
const Port = 18551

// RedirectURL is the redirect_uri of every connect flow and the one redirect
// URL our manifest registers. http on the loopback is allowed only because
// the app has PKCE on (without it Slack treats the redirect as a server one,
// which must be https: https://docs.slack.dev/authentication/using-pkce).
// The plan B spike (Q4) found that Slack matches the redirect with its scheme
// and port and offers no loopback port wildcard, so the port is fixed: with
// 18551 busy nothing can finish a connect (A9). The
// IP literal, not "localhost", is what the listener binds and checks in Host
// (RFC 8252 §8.3).
var RedirectURL = linkScheme + "://127.0.0.1:" + strconv.Itoa(Port) + callbackPath

const (
	// linkScheme is the loopback scheme of the connect link and the
	// redirect URL (a URL scheme, not an LLM transport).
	linkScheme   = "http"
	connectPath  = "/slack/connect"
	callbackPath = "/callback"
)

// ErrNotConnectInput is what ParseConnectInput returns for anything that is
// not a connect link or a connect code.
var ErrNotConnectInput = errors.New("not a Watchtower Slack link or code")

// Target names the workspace and the app a flow connects through.
type Target struct {
	TeamID   string
	ClientID string
	// AccountID is the account row the flow re-binds (Reconnect); 0 means the
	// caller picks the team's live row or a new one.
	AccountID int64
	// CompanySlug ties the connected account to a stored company (#1887:
	// the company connect chain's Slack step); "" leaves the row's tie as
	// it is. Never read from a link or code.
	CompanySlug string
}

var (
	teamIDPattern   = regexp.MustCompile(`^[TE][A-Z0-9]{2,}$`)
	clientIDPattern = regexp.MustCompile(`^[0-9]+\.[0-9]+$`)
)

// ParseConnectInput reads what the owner pasted (or a link the listener
// received): the full connect link
// http://127.0.0.1:18551/slack/connect?team=<team id>&client=<client id>
// or the code <team id>:<client id>, surrounding whitespace ignored. Anything
// else — another scheme, host, port or path, a missing or repeated
// parameter, ids that do not match Slack's shapes — is ErrNotConnectInput.
func ParseConnectInput(s string) (Target, error) {
	s = strings.TrimSpace(s)
	if strings.HasPrefix(s, linkScheme+"://") || strings.Contains(s, "/") {
		return parseLink(s)
	}
	team, client, ok := strings.Cut(s, ":")
	if !ok {
		return Target{}, ErrNotConnectInput
	}
	return validTarget(team, client)
}

func parseLink(s string) (Target, error) {
	u, err := url.Parse(s)
	if err != nil || u.Scheme != linkScheme || u.User != nil || u.Host != linkHost() ||
		u.Path != connectPath || u.Fragment != "" || u.RawFragment != "" || u.Opaque != "" {
		return Target{}, ErrNotConnectInput
	}
	q, err := url.ParseQuery(u.RawQuery)
	if err != nil || len(q["team"]) != 1 || len(q["client"]) != 1 {
		return Target{}, ErrNotConnectInput
	}
	return validTarget(q.Get("team"), q.Get("client"))
}

func validTarget(team, client string) (Target, error) {
	if !teamIDPattern.MatchString(team) || !clientIDPattern.MatchString(client) {
		return Target{}, ErrNotConnectInput
	}
	return Target{TeamID: team, ClientID: client}, nil
}

func linkHost() string { return "127.0.0.1:" + strconv.Itoa(Port) }

// ConnectLink is the link a company's app carries on its About page.
func ConnectLink(t Target) string {
	q := url.Values{"team": {t.TeamID}, "client": {t.ClientID}}
	return linkScheme + "://" + linkHost() + connectPath + "?" + q.Encode()
}

// ConnectCode is the short form of the link: <team id>:<client id>.
func ConnectCode(t Target) string { return fmt.Sprintf("%s:%s", t.TeamID, t.ClientID) }
