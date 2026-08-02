package imap

import (
	"fmt"

	"github.com/emersion/go-imap/v2/imapclient"
	"github.com/emersion/go-sasl"
)

// Authenticator logs an already-connected IMAP client in. Two mechanisms are
// supported today: plain username/password (LOGIN) for generic IMAP servers,
// and XOAUTH2 for OAuth2 providers (Outlook/Office365) — both drive the same
// Client/Syncer, since the wire protocol beyond authentication is identical.
type Authenticator interface {
	Authenticate(c *imapclient.Client) error
}

// PasswordAuth authenticates via the IMAP LOGIN command.
type PasswordAuth struct {
	Username string
	Password string
}

func (a PasswordAuth) Authenticate(c *imapclient.Client) error {
	if err := c.Login(a.Username, a.Password).Wait(); err != nil {
		return fmt.Errorf("imap login: %w", err)
	}
	return nil
}

// XOAUTH2Auth authenticates via SASL XOAUTH2, using an already-obtained
// OAuth2 access token (refreshing that token is the caller's job — see the
// Outlook OAuth flow that supplies it).
type XOAUTH2Auth struct {
	Username    string
	AccessToken string
}

func (a XOAUTH2Auth) Authenticate(c *imapclient.Client) error {
	if err := c.Authenticate(newXOAUTH2Client(a.Username, a.AccessToken)); err != nil {
		return fmt.Errorf("imap xoauth2: %w", err)
	}
	return nil
}

// xoauth2Client implements sasl.Client for the XOAUTH2 mechanism (used by
// Outlook/Office365 and Gmail-as-IMAP), which go-sasl doesn't ship — the
// mechanism is a single initial-response string, so hand-rolling it here is
// simpler than adding another dependency.
type xoauth2Client struct {
	username, accessToken string
}

func newXOAUTH2Client(username, accessToken string) sasl.Client {
	return &xoauth2Client{username: username, accessToken: accessToken}
}

func (a *xoauth2Client) Start() (mech string, ir []byte, err error) {
	mech = "XOAUTH2"
	ir = []byte(fmt.Sprintf("user=%s\x01auth=Bearer %s\x01\x01", a.username, a.accessToken))
	return mech, ir, nil
}

func (a *xoauth2Client) Next(challenge []byte) ([]byte, error) {
	// The server sends a JSON error challenge on failure and expects a single
	// empty response to complete the (failed) exchange — returning an error
	// instead leaves the server waiting for that response.
	return []byte{}, nil
}
