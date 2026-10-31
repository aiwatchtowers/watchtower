// Package client is a Go client of the relay protocol: device registration, challenge-response
// login, operations over HTTPS (POST /v1/op) and a WebSocket connection with live events that
// reconnects by itself. It is used by integration tests, the reference client model (sim) and the
// synthetic probe.
package client

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base32"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"google.golang.org/protobuf/proto"

	relayv1 "watchtower/internal/hub/transport/relay/relayv1"
)

// maxBackoff caps the reconnect delay (spec §4.1).
const maxBackoff = 60 * time.Second

// Retry of operations the server answers UNAVAILABLE to (protocol README, "Errors"): the delay
// starts at 500 ms, doubles up to 8 s, and the whole retrying lasts at most 30 s.
const (
	unavailableFirstDelay = 500 * time.Millisecond
	unavailableMaxDelay   = 8 * time.Second
	unavailableBudget     = 30 * time.Second
)

// pingInterval is how often an open WebSocket is pinged.
const pingInterval = 30 * time.Second

// Clock is the time the client waits on: retry delays and the ping schedule.
type Clock interface {
	Now() time.Time
	// After returns a channel that receives once d has elapsed.
	After(d time.Duration) <-chan time.Time
}

type realClock struct{}

func (realClock) Now() time.Time                         { return time.Now() }
func (realClock) After(d time.Duration) <-chan time.Time { return time.After(d) }

// Error is a protocol error response.
type Error struct {
	E *relayv1.Error
}

func (e *Error) Error() string {
	return fmt.Sprintf("relay: %s: %s", e.E.GetCode(), e.E.GetMessage())
}

// Code returns the protocol error code carried by err, or ERROR_CODE_UNSPECIFIED when err is
// not a protocol error (nil included).
func Code(err error) relayv1.ErrorCode {
	var e *Error
	if errors.As(err, &e) {
		return e.E.GetCode()
	}
	return relayv1.ErrorCode_ERROR_CODE_UNSPECIFIED
}

// Option configures a Client.
type Option func(*Client)

// WithBackoff replaces the reconnect delay function; attempt counts failed reconnects from 0.
func WithBackoff(f func(attempt int) time.Duration) Option { return func(c *Client) { c.backoff = f } }

// WithEventBuffer sets the capacity of a Conn's Events channel (default 256).
func WithEventBuffer(n int) Option { return func(c *Client) { c.eventBuffer = max(n, 1) } }

// WithHTTPClient replaces the HTTP client used for operations.
func WithHTTPClient(h *http.Client) Option { return func(c *Client) { c.http = h } }

// WithClock replaces the clock the retry delays and the ping schedule use (tests).
func WithClock(clk Clock) Option { return func(c *Client) { c.clk = clk } }

// WithOnGoingAway sets a function called (from the connection's reader, so it must not block) each
// time a connection ends with GoingAway: a GoingAway frame, a close with 1001, or both (once).
func WithOnGoingAway(f func()) Option { return func(c *Client) { c.onGoingAway = f } }

// DefaultBackoff doubles from 500 ms up to 60 s and draws the delay uniformly from the upper half
// of that window (jitter).
func DefaultBackoff(attempt int) time.Duration {
	d := min(500*time.Millisecond<<min(attempt, 8), maxBackoff)
	return d/2 + rand.N(d/2+1) //nolint:gosec // jitter, not security
}

// Client is one device's view of the relay. It is safe for concurrent use.
type Client struct {
	base        string // also the server origin signed at login
	key         ed25519.PrivateKey
	kind        relayv1.DeviceKind
	id          string
	http        *http.Client
	backoff     func(int) time.Duration
	onGoingAway func()
	clk         Clock
	// eventBuffer is the capacity of a Conn's Events channel.
	eventBuffer int

	loginMu   sync.Mutex // one login at a time
	mu        sync.Mutex
	token     string
	accountID string // learned by Register; phones only
}

// New returns a client of the relay at baseURL (scheme and host, e.g. https://relay.example.com)
// for the device holding key.
func New(baseURL string, key ed25519.PrivateKey, kind relayv1.DeviceKind, opts ...Option) *Client {
	c := &Client{
		base: strings.TrimRight(baseURL, "/"), key: key, kind: kind,
		id:      DeviceID(key.Public().(ed25519.PublicKey)),
		http:    &http.Client{Timeout: 30 * time.Second},
		backoff: DefaultBackoff, eventBuffer: 256, clk: realClock{},
	}
	for _, o := range opts {
		o(c)
	}
	return c
}

// DeviceID is relay_device_id = lower-case unpadded base32 of SHA-256(auth public key).
func DeviceID(pub ed25519.PublicKey) string {
	sum := sha256.Sum256(pub)
	return strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(sum[:]))
}

// RegisterClientDataHash is the hash a registering device signs with its auth key (and attests with
// App Attest): SHA-256("relay/v1/register" ‖ nonce ‖ auth_pub ‖ server_origin), the strings as UTF-8.
func RegisterClientDataHash(nonce []byte, authPub ed25519.PublicKey, serverOrigin string) []byte {
	h := sha256.New()
	h.Write([]byte("relay/v1/register"))
	h.Write(nonce)
	h.Write(authPub)
	h.Write([]byte(serverOrigin))
	return h.Sum(nil)
}

// VouchClientDataHash is the hash a phone attests a hub with:
// SHA-256("relay/v1/vouch" ‖ nonce ‖ hub_device_id ‖ auth_pub ‖ server_origin), the strings as UTF-8.
func VouchClientDataHash(nonce []byte, hubDeviceID string, authPub ed25519.PublicKey, serverOrigin string) []byte {
	h := sha256.New()
	h.Write([]byte("relay/v1/vouch"))
	h.Write(nonce)
	h.Write([]byte(hubDeviceID))
	h.Write(authPub)
	h.Write([]byte(serverOrigin))
	return h.Sum(nil)
}

// DeviceID returns this device's relay_device_id.
func (c *Client) DeviceID() string { return c.id }

// Register registers the device's public key (idempotent) and returns its device id. It first asks
// for a registration nonce and registers with it and the auth key's signature over
// RegisterClientDataHash. The attestation stays empty: a relay with App Attest off ignores the three
// fields, and the probe's devices are exempt from it where it is on. A phone also learns its account
// id (AccountID).
func (c *Client) Register(ctx context.Context) (string, error) {
	pub := c.key.Public().(ed25519.PublicKey)
	ch, err := c.Do(ctx, &relayv1.Request{Op: &relayv1.Request_Challenge{Challenge: &relayv1.GetChallenge{
		DeviceId: c.id, Purpose: relayv1.ChallengePurpose_CHALLENGE_PURPOSE_REGISTER,
	}}})
	if err != nil {
		return "", err
	}
	nonce := ch.GetChallenge().GetNonce()
	resp, err := c.Do(ctx, &relayv1.Request{Op: &relayv1.Request_Register{Register: &relayv1.RegisterDevice{
		DeviceKind: c.kind, AuthPub: pub, Nonce: nonce,
		Signature: ed25519.Sign(c.key, RegisterClientDataHash(nonce, pub, c.base)),
	}}})
	if err != nil {
		return "", err
	}
	if id := resp.GetRegistered().GetDeviceId(); id != c.id {
		return "", fmt.Errorf("relay: server device id %q differs from %q", id, c.id)
	}
	c.mu.Lock()
	c.accountID = resp.GetRegistered().GetAccountId()
	c.mu.Unlock()
	return c.id, nil
}

// AccountID returns the phone's account id (the StoreKit appAccountToken) learned by the last
// Register; empty for a Mac or before Register.
func (c *Client) AccountID() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.accountID
}

// VouchHub vouches, as this phone, for the hub with key hubPub, so that a following add_slot or
// promote_pairing of that hub succeeds within the 10-minute vouch window. It takes a VOUCH challenge
// for this phone and sends vouch_hub without an attestation: the Go client runs against a relay with
// App Attest off or as a device on RELAY_ATTEST_EXEMPT_DEVICES.
func (c *Client) VouchHub(ctx context.Context, hubPub ed25519.PublicKey) error {
	ch, err := c.Do(ctx, &relayv1.Request{Op: &relayv1.Request_Challenge{Challenge: &relayv1.GetChallenge{
		DeviceId: c.id, Purpose: relayv1.ChallengePurpose_CHALLENGE_PURPOSE_VOUCH,
	}}})
	if err != nil {
		return err
	}
	_, err = c.Do(ctx, &relayv1.Request{Op: &relayv1.Request_VouchHub{VouchHub: &relayv1.VouchHub{
		HubDeviceId: DeviceID(hubPub), AuthPub: hubPub, Nonce: ch.GetChallenge().GetNonce(),
	}}})
	return err
}

// Login opens a new session by challenge-response.
func (c *Client) Login(ctx context.Context) error {
	c.loginMu.Lock()
	defer c.loginMu.Unlock()
	return c.loginLocked(ctx)
}

func (c *Client) loginLocked(ctx context.Context) error {
	resp, err := c.Do(ctx, &relayv1.Request{Op: &relayv1.Request_Challenge{Challenge: &relayv1.GetChallenge{DeviceId: c.id}}})
	if err != nil {
		return err
	}
	nonce := resp.GetChallenge().GetNonce()
	msg := make([]byte, 0, len(nonce)+len(c.id)+len(c.base))
	msg = append(append(append(msg, nonce...), c.id...), c.base...)
	resp, err = c.Do(ctx, &relayv1.Request{Op: &relayv1.Request_Login{Login: &relayv1.Login{
		DeviceId: c.id, Nonce: nonce, Signature: ed25519.Sign(c.key, msg),
	}}})
	if err != nil {
		return err
	}
	c.mu.Lock()
	c.token = resp.GetSession().GetToken()
	c.mu.Unlock()
	return nil
}

// sessionToken returns a token, logging in when there is none or when the current one is stale
// (the token a request was refused with).
func (c *Client) sessionToken(ctx context.Context, stale string) (string, error) {
	c.mu.Lock()
	tok := c.token
	c.mu.Unlock()
	if tok != "" && tok != stale {
		return tok, nil
	}
	c.loginMu.Lock()
	defer c.loginMu.Unlock()
	c.mu.Lock()
	tok = c.token
	c.mu.Unlock()
	if tok != "" && tok != stale { // another caller logged in meanwhile
		return tok, nil
	}
	if err := c.loginLocked(ctx); err != nil {
		return "", err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.token, nil
}

func isPublic(req *relayv1.Request) bool {
	switch req.GetOp().(type) {
	case *relayv1.Request_Register, *relayv1.Request_Challenge, *relayv1.Request_Login:
		return true
	}
	return false
}

// Do performs one operation over HTTPS. An error response is returned together with an *Error; a
// transport failure returns a plain error. A request refused as UNAUTHENTICATED (expired session)
// is retried once after a new login. A request answered UNAVAILABLE is retried with a growing
// delay for up to 30 s (the server makes every such operation idempotent), then the error is
// returned.
func (c *Client) Do(ctx context.Context, req *relayv1.Request) (*relayv1.Response, error) {
	return c.retryUnavailable(ctx, func() (*relayv1.Response, error) { return c.doOnce(ctx, req) })
}

// retryUnavailable calls fn until it stops failing with UNAVAILABLE or the 30 s budget is spent.
func (c *Client) retryUnavailable(ctx context.Context, fn func() (*relayv1.Response, error)) (*relayv1.Response, error) {
	start := c.clk.Now()
	delay := unavailableFirstDelay
	for {
		resp, err := fn()
		if Code(err) != relayv1.ErrorCode_ERROR_CODE_UNAVAILABLE {
			return resp, err
		}
		left := unavailableBudget - c.clk.Now().Sub(start)
		if left <= 0 {
			return resp, err
		}
		select {
		case <-c.clk.After(min(delay, left)):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		delay = min(delay*2, unavailableMaxDelay)
	}
}

func (c *Client) doOnce(ctx context.Context, req *relayv1.Request) (*relayv1.Response, error) {
	if isPublic(req) {
		return c.post(ctx, req, "")
	}
	tok, err := c.sessionToken(ctx, "")
	if err != nil {
		return nil, err
	}
	resp, err := c.post(ctx, req, tok)
	if Code(err) == relayv1.ErrorCode_ERROR_CODE_UNAUTHENTICATED {
		if tok, err = c.sessionToken(ctx, tok); err != nil {
			return nil, err
		}
		resp, err = c.post(ctx, req, tok)
	}
	return resp, err
}

func (c *Client) post(ctx context.Context, req *relayv1.Request, token string) (*relayv1.Response, error) {
	body, err := proto.Marshal(req)
	if err != nil {
		return nil, err
	}
	hr, err := http.NewRequestWithContext(ctx, http.MethodPost, c.base+"/v1/op", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	hr.Header.Set("Content-Type", "application/x-protobuf")
	hr.Header.Set("Relay-Protocol-Version", strconv.Itoa(relayv1.ProtocolVersion))
	if token != "" {
		hr.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := c.http.Do(hr)
	if err != nil {
		return nil, err
	}
	defer func() { _ = res.Body.Close() }()
	b, err := io.ReadAll(res.Body)
	if err != nil {
		return nil, err
	}
	var resp relayv1.Response
	if err := proto.Unmarshal(b, &resp); err != nil {
		return nil, fmt.Errorf("relay: HTTP %d: undecodable response", res.StatusCode)
	}
	return &resp, errorOf(&resp)
}

// errorOf returns the response's protocol error; UNSUPPORTED_VERSION also matches
// ErrUnsupportedVersion, so reconnect loops stop instead of retrying.
func errorOf(resp *relayv1.Response) error {
	e := resp.GetError()
	if e == nil {
		return nil
	}
	if e.GetCode() == relayv1.ErrorCode_ERROR_CODE_UNSUPPORTED_VERSION {
		return fmt.Errorf("%w: %w", ErrUnsupportedVersion, &Error{E: e})
	}
	return &Error{E: e}
}

// invalidate forgets token if it is still the current one, so the next use logs in again.
func (c *Client) invalidate(token string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.token == token {
		c.token = ""
	}
}
