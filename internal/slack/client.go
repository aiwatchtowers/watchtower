// Package slack provides Slack API client and utilities with rate limiting support.
package slack

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/slack-go/slack"

	"watchtower/internal/netsec"
)

// Client wraps the slack-go client with rate limiting. It keeps the token,
// API URL and HTTP client itself for the calls it makes without slack-go
// (search.messages decoded raw, file downloads).
type Client struct {
	api         *slack.Client
	token       string
	apiURL      string
	http        *http.Client
	files       *http.Client // file downloads: no whole-request timeout, the Slack-host redirect rule
	teamDomain  atomic.Pointer[string]
	rateLimiter *RateLimiter
	logger      *log.Logger
	answered    atomic.Uint64 // AnsweredCalls
}

// Timeouts bounding every Slack API request. slack-go's default client has no
// timeout at all, so a socket left dead by a laptop sleep hangs the request
// until the OS gives up on the TCP connection — measured at ~24 minutes on
// macOS, long enough to stall a whole sync cycle. The idle-connection pool
// cannot expire such a socket either: Go's monotonic clock stops while the
// machine sleeps, so an idle timer that "expired" during sleep never fires.
// The same clock bounds these timeouts, so they count awake time only: a
// request caught by a sleep can take far longer in wall time. The daemon
// therefore cancels a cycle a sleep interrupted and drops the pooled
// connections (CloseIdleConnections) before the next one
// (internal/daemon/wake.go).
const (
	// httpTimeout is the whole-request ceiling, matching every other
	// integration in this repo (jira, gmail, calendar, caldav, imap). It is a
	// backstop, not the working bound — a healthy Slack call answers in
	// well under a second.
	httpTimeout = 30 * time.Second

	// responseHeaderTimeout bounds the wait for response headers. It only
	// applies to HTTP/1.1 connections (the field lives on http.Transport);
	// slack.com negotiates HTTP/2, where the h2 keepalive below is what
	// actually detects a dead connection.
	responseHeaderTimeout = 10 * time.Second

	// h2ReadIdleTimeout makes the HTTP/2 transport ping a connection that has
	// been idle this long, and h2PingTimeout drops it when the ping goes
	// unanswered. This is the one bound that kills a sleep-killed socket
	// *before* a request is sent down it, rather than making the request wait.
	h2ReadIdleTimeout = 30 * time.Second
	h2PingTimeout     = 10 * time.Second
)

// transport is the one connection pool every Slack client shares, so
// CloseIdleConnections reaches all of them.
var transport = newTransport()

// newTransport builds the bounded transport behind every Slack call.
func newTransport() *http.Transport {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.ResponseHeaderTimeout = responseHeaderTimeout
	// HTTP/2 health checks: a ping after ReadIdleTimeout of silence, the
	// connection dropped when it goes unanswered for PingTimeout.
	tr.HTTP2 = &http.HTTP2Config{
		SendPingTimeout: h2ReadIdleTimeout,
		PingTimeout:     h2PingTimeout,
	}
	return tr
}

// newHTTPClient builds the bounded HTTP client every Slack call goes through.
func newHTTPClient() *http.Client {
	return &http.Client{Timeout: httpTimeout, Transport: transport}
}

// CloseIdleConnections drops every idle pooled Slack connection, so the next
// call dials afresh instead of writing into a socket a sleep left dead.
func CloseIdleConnections() {
	transport.CloseIdleConnections()
}

// NewClient creates a new rate-limited Slack client.
func NewClient(token string) *Client {
	return newClient(token, slack.APIURL, NewRateLimiter())
}

// NewClientWithAPIURL creates a client whose API calls go to apiURL (with a
// trailing slash; a test's httptest server).
func NewClientWithAPIURL(token, apiURL string) *Client {
	return newClient(token, apiURL, NewRateLimiter())
}

// NewClientWithAPIURLUnlimited is NewClientWithAPIURL with an unlimited rate
// limiter (for testing).
func NewClientWithAPIURLUnlimited(token, apiURL string) *Client {
	return newClient(token, apiURL, NewUnlimitedRateLimiter())
}

func newClient(token, apiURL string, rl *RateLimiter) *Client {
	hc := newHTTPClient()
	c := &Client{
		api:         slack.New(token, slack.OptionAPIURL(apiURL), slack.OptionHTTPClient(hc)),
		token:       token,
		apiURL:      apiURL,
		http:        hc,
		rateLimiter: rl,
	}
	c.files = &http.Client{Timeout: fileDownloadTimeout, Transport: transport, CheckRedirect: c.fileRedirect}
	return c
}

// SetLogger sets a logger for the client and its rate limiter.
func (c *Client) SetLogger(l *log.Logger) {
	c.logger = l
	c.rateLimiter.logger = l
}

func (c *Client) logf(format string, args ...any) {
	if c.logger != nil {
		c.logger.Printf(format, args...)
	}
}

// doRequest acquires the gate, calls fn, handles errors, and releases the gate.
// Rate limit (429) errors are retried automatically after the backoff period.
func (c *Client) doRequest(ctx context.Context, tier int, fn func() error) error {
	const maxRetries = 3
	for attempt := 0; attempt <= maxRetries; attempt++ {
		if err := c.rateLimiter.Wait(ctx, tier); err != nil {
			return err
		}
		err := fn()
		c.handleError(tier, err) // set backoff BEFORE releasing gate
		c.rateLimiter.Done(tier)
		if isSlackAnswer(err) {
			c.answered.Add(1)
		}

		if err == nil {
			return nil
		}

		// Retry on rate limit errors; handleError already set the backoff.
		var rlErr *slack.RateLimitedError
		if errors.As(err, &rlErr) && attempt < maxRetries {
			c.logf("rate limited, retrying (attempt %d/%d)", attempt+1, maxRetries)
			continue
		}
		return err
	}
	return nil // unreachable
}

// AuthTestResponse holds the result of an auth.test API call.
type AuthTestResponse struct {
	UserID string
	User   string // username
	TeamID string
}

// AuthTest calls the auth.test API to identify the token owner. (Tier 2)
func (c *Client) AuthTest(ctx context.Context) (*AuthTestResponse, error) {
	var resp *slack.AuthTestResponse
	err := c.doRequest(ctx, Tier2, func() error {
		c.logf("slack API: auth.test")
		var err error
		resp, err = c.api.AuthTestContext(ctx)
		return err
	})
	if err != nil {
		return nil, err
	}
	return &AuthTestResponse{
		UserID: resp.UserID,
		User:   resp.User,
		TeamID: resp.TeamID,
	}, nil
}

// GetTeamInfo returns workspace information. (Tier 2)
func (c *Client) GetTeamInfo(ctx context.Context) (*slack.TeamInfo, error) {
	var info *slack.TeamInfo
	err := c.doRequest(ctx, Tier2, func() error {
		c.logf("slack API: team.info")
		var err error
		info, err = c.api.GetTeamInfoContext(ctx)
		return err
	})
	return info, err
}

// GetUsers returns all users in the workspace, handling pagination. (Tier 2)
// The optional onPage callback is called after each page with the running total.
func (c *Client) GetUsers(ctx context.Context, onPage ...func(fetched int)) ([]slack.User, error) {
	var allUsers []slack.User

	p := c.api.GetUsersPaginated(slack.GetUsersOptionLimit(200))
	for {
		var done bool
		err := c.doRequest(ctx, Tier2, func() error {
			c.logf("slack API: users.list (fetched so far: %d)", len(allUsers))
			var err error
			p, err = p.Next(ctx)
			if err != nil && p.Done(err) {
				done = true
				return nil
			}
			return err
		})
		if err != nil {
			return allUsers, err
		}
		if done {
			break
		}
		allUsers = append(allUsers, p.Users...)
		if len(onPage) > 0 && onPage[0] != nil {
			onPage[0](len(allUsers))
		}
	}

	return allUsers, nil
}

// GetChannels returns channels of the specified types, handling pagination. (Tier 2)
// If types is empty, fetches public and private channels only.
// The optional onPage callback is called after each page with the running total.
func (c *Client) GetChannels(ctx context.Context, types []string, onPage ...func(fetched int)) ([]slack.Channel, error) {
	if len(types) == 0 {
		types = []string{"public_channel", "private_channel"}
	}
	var allChannels []slack.Channel
	cursor := ""

	for {
		var channels []slack.Channel
		var nextCursor string
		err := c.doRequest(ctx, Tier2, func() error {
			c.logf("slack API: conversations.list (fetched so far: %d)", len(allChannels))
			var err error
			channels, nextCursor, err = c.api.GetConversationsContext(ctx, &slack.GetConversationsParameters{
				Types:  types,
				Limit:  200,
				Cursor: cursor,
			})
			return err
		})
		if err != nil {
			return allChannels, err
		}

		allChannels = append(allChannels, channels...)
		if len(onPage) > 0 && onPage[0] != nil {
			onPage[0](len(allChannels))
		}

		if nextCursor == "" {
			break
		}
		cursor = nextCursor
	}

	return allChannels, nil
}

// GetChannelReadCursor fetches the last_read timestamp for a single channel via conversations.info. (Tier 3)
// Returns the last_read string (Slack ts) and any error.
func (c *Client) GetChannelReadCursor(ctx context.Context, channelID string) (string, error) {
	var ch *slack.Channel
	err := c.doRequest(ctx, Tier3, func() error {
		c.logf("slack API: conversations.info channel=%s", channelID)
		var err error
		ch, err = c.api.GetConversationInfoContext(ctx, &slack.GetConversationInfoInput{
			ChannelID: channelID,
		})
		return err
	})
	if err != nil {
		return "", err
	}
	return ch.LastRead, nil
}

// HistoryOptions configures a conversation history request.
type HistoryOptions struct {
	ChannelID string
	Cursor    string
	Oldest    string
	Latest    string
	Limit     int
	// Inclusive includes the messages at Oldest and Latest themselves.
	Inclusive bool
}

// HistoryResponse contains messages and pagination info from conversation history.
type HistoryResponse struct {
	Messages   []slack.Message
	HasMore    bool
	NextCursor string
}

// GetConversationHistory fetches one page of message history. (Tier 3)
func (c *Client) GetConversationHistory(ctx context.Context, opts HistoryOptions) (*HistoryResponse, error) {
	limit := opts.Limit
	if limit == 0 {
		limit = 200
	}

	var resp *slack.GetConversationHistoryResponse
	err := c.doRequest(ctx, Tier3, func() error {
		c.logf("slack API: conversations.history channel=%s oldest=%s cursor=%q", opts.ChannelID, opts.Oldest, opts.Cursor)
		var err error
		resp, err = c.api.GetConversationHistoryContext(ctx, &slack.GetConversationHistoryParameters{
			ChannelID: opts.ChannelID,
			Cursor:    opts.Cursor,
			Oldest:    opts.Oldest,
			Latest:    opts.Latest,
			Limit:     limit,
			Inclusive: opts.Inclusive,
		})
		return err
	})
	if err != nil {
		return nil, err
	}

	return &HistoryResponse{
		Messages:   resp.Messages,
		HasMore:    resp.HasMore,
		NextCursor: resp.ResponseMetaData.NextCursor,
	}, nil
}

// GetConversationReplies fetches all replies for a thread, handling pagination. (Tier 3)
func (c *Client) GetConversationReplies(ctx context.Context, channelID, threadTS string) ([]slack.Message, error) {
	var allMessages []slack.Message
	cursor := ""

	for {
		var msgs []slack.Message
		var hasMore bool
		var nextCursor string

		err := c.doRequest(ctx, Tier3, func() error {
			c.logf("slack API: conversations.replies channel=%s thread=%s", channelID, threadTS)
			var err error
			msgs, hasMore, nextCursor, err = c.api.GetConversationRepliesContext(ctx, &slack.GetConversationRepliesParameters{
				ChannelID: channelID,
				Timestamp: threadTS,
				Cursor:    cursor,
				Limit:     200,
			})
			return err
		})
		if err != nil {
			return allMessages, err
		}

		allMessages = append(allMessages, msgs...)

		if !hasMore || nextCursor == "" {
			break
		}
		cursor = nextCursor
	}

	return allMessages, nil
}

// PostMessage posts text into channelID as the token's owner (a user token
// posts as that user), as a thread reply when threadTS is set, and returns
// the new message's ts. A 429 is retried by doRequest — Slack rejected that
// request, so nothing was posted. (Tier 3)
func (c *Client) PostMessage(ctx context.Context, channelID, text, threadTS string) (string, error) {
	opts := []slack.MsgOption{slack.MsgOptionText(text, false)}
	if threadTS != "" {
		opts = append(opts, slack.MsgOptionTS(threadTS))
	}
	var ts string
	err := c.doRequest(ctx, Tier3, func() error {
		c.logf("slack API: chat.postMessage channel=%s thread=%s", channelID, threadTS)
		var err error
		_, ts, err = c.api.PostMessageContext(ctx, channelID, opts...)
		return err
	})
	if err != nil {
		return "", err
	}
	return ts, nil
}

// OpenDM returns the id of the direct-message channel between the token's
// owner and userID, opening it when it does not exist yet. (Tier 3)
func (c *Client) OpenDM(ctx context.Context, userID string) (string, error) {
	var ch *slack.Channel
	err := c.doRequest(ctx, Tier3, func() error {
		c.logf("slack API: conversations.open user=%s", userID)
		var err error
		ch, _, _, err = c.api.OpenConversationContext(ctx, &slack.OpenConversationParameters{Users: []string{userID}, ReturnIM: true})
		return err
	})
	if err != nil {
		return "", err
	}
	if ch == nil || ch.ID == "" {
		return "", errors.New("conversations.open returned no channel")
	}
	return ch.ID, nil
}

// SearchMatch is one search.messages match with the fields slack-go's
// SearchMessage drops: the message's files, subtype and upload flag.
type SearchMatch struct {
	slack.SearchMessage
	Files   []slack.File `json:"files"`
	Subtype string       `json:"subtype"`
	Upload  bool         `json:"upload"`
}

// SearchResult holds one page of search.messages results.
type SearchResult struct {
	Messages []SearchMatch
	Total    int
	Page     int
	Pages    int
}

// searchResponse is search.messages' answer, decoded raw.
type searchResponse struct {
	slack.SlackResponse
	Messages struct {
		Matches []SearchMatch `json:"matches"`
		Paging  slack.Paging  `json:"paging"`
		Total   int           `json:"total"`
	} `json:"messages"`
}

// SearchMessages searches for messages matching the query. (Tier 2)
// Returns one page of results; use page parameter for pagination (1-indexed).
// The call is made here rather than through slack-go, whose SearchMessage
// drops each match's files; a 429 and a Slack error come back as slack-go's
// own error types, so the retry and backoff in doRequest are unchanged.
func (c *Client) SearchMessages(ctx context.Context, query string, page int) (*SearchResult, error) {
	var result searchResponse
	err := c.doRequest(ctx, Tier2, func() error {
		c.logf("slack API: search.messages query=%q page=%d", query, page)
		result = searchResponse{}
		return c.postAPI(ctx, "search.messages", url.Values{
			"query":    {query},
			"sort":     {"timestamp"},
			"sort_dir": {"asc"},
			"count":    {"100"},
			"page":     {strconv.Itoa(page)},
		}, &result)
	})
	if err != nil {
		return nil, err
	}

	return &SearchResult{
		Messages: result.Messages.Matches,
		Total:    result.Messages.Total,
		Page:     result.Messages.Paging.Page,
		Pages:    result.Messages.Paging.Pages,
	}, nil
}

// postAPI posts a form to one Web API method with the token as a bearer
// header and decodes the JSON answer into dst. A non-200 status is slack-go's
// RateLimitedError (429 with Retry-After) or StatusCodeError; ok:false is
// dst.Err(), a SlackErrorResponse.
func (c *Client) postAPI(ctx context.Context, method string, form url.Values, dst interface{ Err() error }) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.apiURL+method, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Authorization", "Bearer "+c.token)
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := statusError(resp); err != nil {
		return err
	}
	if err := json.NewDecoder(resp.Body).Decode(dst); err != nil {
		return err
	}
	return dst.Err()
}

// statusError maps a non-200 answer the way slack-go does: a 429 with a
// parsable Retry-After is a RateLimitedError, any other a StatusCodeError.
func statusError(resp *http.Response) error {
	if resp.StatusCode == http.StatusTooManyRequests {
		if secs, err := strconv.ParseInt(resp.Header.Get("Retry-After"), 10, 64); err == nil {
			return &slack.RateLimitedError{RetryAfter: time.Duration(secs) * time.Second}
		}
	}
	if resp.StatusCode != http.StatusOK {
		return slack.StatusCodeError{Code: resp.StatusCode, Status: resp.Status}
	}
	return nil
}

// fileDownloadTimeout backstops one file download, body included (the
// caller's context is the working bound).
const fileDownloadTimeout = 2 * time.Minute

// File download errors.
var (
	// ErrTooLarge: the file is larger than the caller's limit.
	ErrTooLarge = errors.New("slack: file larger than the download limit")
	// ErrFileGone: Slack answered 404 or 410 for the file.
	ErrFileGone = errors.New("slack: file not found")
	// ErrFileURLRefused: the URL, or a redirect, is not one of the account's
	// Slack file hosts over https. No request carries the token there.
	ErrFileURLRefused = errors.New("slack: file URL refused")
)

// SetTeamDomain sets the account's workspace domain (slack_accounts.team_domain),
// whose <domain>.slack.com host DownloadFile accepts beside files.slack.com.
func (c *Client) SetTeamDomain(domain string) {
	d := strings.ToLower(strings.TrimSpace(domain))
	c.teamDomain.Store(&d)
}

// fileHostAllowed reports an https URL, no userinfo, default port, on
// files.slack.com or the account's own <team_domain>.slack.com.
func (c *Client) fileHostAllowed(u *url.URL) bool {
	if u == nil || u.Scheme != "https" || u.User != nil || (u.Port() != "" && u.Port() != "443") {
		return false
	}
	host := strings.ToLower(u.Hostname())
	if host == "files.slack.com" {
		return true
	}
	d := c.teamDomain.Load()
	return d != nil && validDomainLabel(*d) && host == *d+".slack.com"
}

// validDomainLabel reports one DNS label (a Slack workspace domain).
func validDomainLabel(s string) bool {
	if s == "" || len(s) > 63 || s[0] == '-' || s[len(s)-1] == '-' {
		return false
	}
	for _, r := range s {
		if (r < 'a' || r > 'z') && (r < '0' || r > '9') && r != '-' {
			return false
		}
	}
	return true
}

// fileRedirect is the download client's CheckRedirect: netsec.SecretRedirect
// (https, the first request's host) and the Slack file host allowlist.
func (c *Client) fileRedirect(req *http.Request, via []*http.Request) error {
	if err := netsec.SecretRedirect("Slack file download")(req, via); err != nil {
		return fmt.Errorf("%w: %v", ErrFileURLRefused, err)
	}
	if !c.fileHostAllowed(req.URL) {
		return fmt.Errorf("%w: redirect to a host other than the Slack file hosts", ErrFileURLRefused)
	}
	return nil
}

// DownloadFile opens a file's url_private(_download) with the account's
// token as a bearer header. (Tier 4, the gate GetUserInfo shares.) Only
// https://files.slack.com and https://<team_domain>.slack.com are fetched;
// any other URL is ErrFileURLRefused before a request is made, and so is a
// redirect off the first request's host. A size over limit is ErrTooLarge,
// at the headers or while reading. The type returned is the declared one.
func (c *Client) DownloadFile(ctx context.Context, fileURL string, limit int64) (io.ReadCloser, string, error) {
	u, err := url.Parse(fileURL)
	if err != nil || !c.fileHostAllowed(u) {
		return nil, "", ErrFileURLRefused
	}
	var resp *http.Response
	err = c.doRequest(ctx, Tier4, func() error {
		c.logf("slack API: file download")
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "Bearer "+c.token)
		r, err := c.files.Do(req)
		if err != nil {
			return err
		}
		if err := statusError(r); err != nil {
			_ = r.Body.Close()
			return err
		}
		resp = r
		return nil
	})
	if err != nil {
		var sc slack.StatusCodeError
		if errors.As(err, &sc) && (sc.Code == http.StatusNotFound || sc.Code == http.StatusGone) {
			return nil, "", ErrFileGone
		}
		return nil, "", err
	}
	if resp.ContentLength > limit {
		_ = resp.Body.Close()
		return nil, "", ErrTooLarge
	}
	return &limitedBody{rc: resp.Body, limit: limit}, resp.Header.Get("Content-Type"), nil
}

// limitedBody fails with ErrTooLarge once more than limit bytes are read:
// that Read returns the bytes up to the limit, and every later Read 0 and
// ErrTooLarge (the error is latched).
type limitedBody struct {
	rc          io.ReadCloser
	limit, read int64
	err         error
}

func (b *limitedBody) Read(p []byte) (int, error) {
	if b.err != nil {
		return 0, b.err
	}
	n, err := b.rc.Read(p)
	b.read += int64(n)
	if b.read > b.limit {
		b.err = ErrTooLarge
		return n - int(b.read-b.limit), b.err
	}
	return n, err
}

func (b *limitedBody) Close() error { return b.rc.Close() }

// GetUserInfo fetches a single user's profile. (Tier 4)
func (c *Client) GetUserInfo(ctx context.Context, userID string) (*slack.User, error) {
	var user *slack.User
	err := c.doRequest(ctx, Tier4, func() error {
		c.logf("slack API: users.info user=%s", userID)
		var err error
		user, err = c.api.GetUserInfoContext(ctx, userID)
		return err
	})
	return user, err
}

// GetEmoji fetches all custom emojis in the workspace. (Tier 2)
// Returns a map of emoji name → URL (or "alias:other_name" for aliases).
func (c *Client) GetEmoji(ctx context.Context) (map[string]string, error) {
	var emojis map[string]string
	err := c.doRequest(ctx, Tier2, func() error {
		c.logf("slack API: emoji.list")
		var err error
		emojis, err = c.api.GetEmojiContext(ctx)
		return err
	})
	return emojis, err
}

// maxReactionListPages bounds ListUserReactions so a heavy reactor's history
// can never spin the poll forever; 20 pages × 100 = the 2000 most recent
// reactions, far past the dictionary emojis a single poll cares about.
const maxReactionListPages = 20

// ListUserReactions returns the items the given user has reacted to
// (reactions.list, Tier 3), across all pages up to maxReactionListPages. Full
// is set so each message item carries its ts. userID is the RAW Slack user id
// (no account prefix). This is the reaction-command detection source: called
// under the owner's own token, it enumerates exactly the owner's reactions
// regardless of message age.
func (c *Client) ListUserReactions(ctx context.Context, userID string) ([]slack.ReactedItem, error) {
	var out []slack.ReactedItem
	params := slack.NewListReactionsParameters()
	params.User = userID
	params.Full = true
	params.Count = 100
	for page := 1; page <= maxReactionListPages; page++ {
		params.Page = page
		var (
			items  []slack.ReactedItem
			paging *slack.Paging
		)
		err := c.doRequest(ctx, Tier3, func() error {
			c.logf("slack API: reactions.list user=%s page=%d", userID, page)
			var err error
			items, paging, err = c.api.ListReactionsContext(ctx, params)
			return err
		})
		if err != nil {
			return nil, err
		}
		out = append(out, items...)
		if paging == nil || page >= paging.Pages || len(items) == 0 {
			break
		}
	}
	return out, nil
}

// APIStats returns per-tier request counts and total 429 retry count.
func (c *Client) APIStats() (counts map[int]int, retries int) {
	return c.rateLimiter.Stats()
}

// ResetAPIStats clears all request counters.
func (c *Client) ResetAPIStats() {
	c.rateLimiter.ResetStats()
}

// AnsweredCalls counts the requests Slack answered — a success, an API
// error, a 429, an HTTP status error — over the client's lifetime. Any other
// failure does not count: one on the wire (a timeout, a dead socket, a
// cancelled ctx) and one that broke off mid-body after the headers came (a
// truncated or stalled response, which slack-go returns unwrapped). Unlike
// APIStats it is never reset, so a caller that compares two readings sees
// every answer in between: the daemon reads a change as its Slack sync
// making progress.
func (c *Client) AnsweredCalls() uint64 {
	return c.answered.Load()
}

// isSlackAnswer reports whether a request ended with a complete answer from
// Slack: no error, or one of the errors slack-go builds from a response it
// read in full (an API error, a 429, a non-2xx status).
func isSlackAnswer(err error) bool {
	if err == nil {
		return true
	}
	var apiErr slack.SlackErrorResponse
	var rateErr *slack.RateLimitedError
	var statusErr slack.StatusCodeError
	return errors.As(err, &apiErr) || errors.As(err, &rateErr) || errors.As(err, &statusErr)
}

// handleError checks for rate limit errors and sets backoff accordingly.
func (c *Client) handleError(tier int, err error) {
	if err == nil {
		return
	}
	var rlErr *slack.RateLimitedError
	if errors.As(err, &rlErr) {
		c.rateLimiter.HandleRateLimit(tier, rlErr.RetryAfter)
	}
}
