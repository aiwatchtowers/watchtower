package confluence

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"strings"
	"time"

	"watchtower/internal/extsync"
	"watchtower/internal/jira"
)

// API is the slice of *jira.ConfluenceAPI the fetcher needs (tests fake it).
// Both methods issue GET requests only (EXT-01): the fetcher has no way to
// write to Confluence.
type API interface {
	GetJSON(ctx context.Context, path string, q url.Values, out any) error
	Download(ctx context.Context, path string, limit int64) (io.ReadCloser, error)
}

var _ API = (*jira.ConfluenceAPI)(nil)

// errNotFound marks a cursor-less listing that answered 404: the listed
// parent is gone. A 404 on a call that carried a cursor is never mapped to
// it — a rejected cursor must surface as an error (R8).
var errNotFound = errors.New("confluence: not found")

// mapErr maps a Confluence API error onto the extsync sentinels (controller
// ruling R1): a revoked grant becomes extsync.ErrAuthRevoked, a 401 or 403
// naming a missing scope becomes extsync.ErrNeedsConsent (Atlassian answers
// a scope the grant lacks with 401 "Unauthorized; scope does not match";
// jira.Client returns that as *HTTPStatusError rather than ErrAuthRevoked).
// The original error stays in the chain, so isNotFound and errors.As keep
// working on the result.
func mapErr(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, jira.ErrAuthRevoked) {
		return fmt.Errorf("%w: %w", extsync.ErrAuthRevoked, err)
	}
	var he *jira.HTTPStatusError
	if errors.As(err, &he) && (he.Status == 401 || he.Status == 403) && strings.Contains(strings.ToLower(he.Body), "scope") {
		return fmt.Errorf("%w: %w", extsync.ErrNeedsConsent, err)
	}
	return err
}

// isNotFound reports whether err is a 404 response.
func isNotFound(err error) bool {
	var he *jira.HTTPStatusError
	return errors.As(err, &he) && he.Status == 404
}

// nextCursor extracts the cursor query parameter of a _links.next link
// ("" when there is no next page). Pagination is cursor-only: a next link
// without a cursor (offset paging, which can skip items under concurrent
// edits) is an error rather than something to follow.
func nextCursor(next string) (string, error) {
	if next == "" {
		return "", nil
	}
	u, err := url.Parse(next)
	if err != nil {
		return "", fmt.Errorf("confluence: bad next link %q: %w", next, err)
	}
	c := u.Query().Get("cursor")
	if c == "" {
		return "", fmt.Errorf("confluence: next link without a cursor: %q", next)
	}
	return c, nil
}

// parseTime parses an API timestamp (ISO 8601, optional fractional
// seconds).
func parseTime(s string) (time.Time, error) {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}, fmt.Errorf("confluence: bad timestamp %q: %w", s, err)
	}
	return t, nil
}

// parseOptionalTime is parseTime where an empty value is the zero time.
func parseOptionalTime(s string) (time.Time, error) {
	if s == "" {
		return time.Time{}, nil
	}
	return parseTime(s)
}

// links is the _links object shared by v1 and v2 responses.
type links struct {
	Next     string `json:"next"`
	WebUI    string `json:"webui"`
	Download string `json:"download"`
}

// flexID decodes an id sent either as a JSON string or a JSON number: in v1
// responses a content container id is a string, a space container id a
// number.
type flexID string

func (f *flexID) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err == nil {
		*f = flexID(s)
		return nil
	}
	var n json.Number
	if err := json.Unmarshal(b, &n); err != nil {
		return fmt.Errorf("confluence: bad id %s: %w", b, err)
	}
	*f = flexID(n.String())
	return nil
}

// --- v1 content search (/wiki/rest/api/content/search) ---

type searchResponse struct {
	Results []searchContent `json:"results"`
	Links   links           `json:"_links"`
}

type searchContent struct {
	ID      string `json:"id"`
	Type    string `json:"type"`
	Status  string `json:"status"`
	Title   string `json:"title"`
	Version struct {
		Number int    `json:"number"`
		When   string `json:"when"`
	} `json:"version"`
	Container struct {
		ID   flexID `json:"id"`
		Type string `json:"type"`
	} `json:"container"`
	Ancestors []struct {
		ID    string `json:"id"`
		Title string `json:"title"`
	} `json:"ancestors"`
}

// --- v2 (/wiki/api/v2/...) ---

type v2Version struct {
	Number    int    `json:"number"`
	CreatedAt string `json:"createdAt"`
	AuthorID  string `json:"authorId"`
}

type v2Body struct {
	Storage struct {
		Value string `json:"value"`
	} `json:"storage"`
}

type v2Space struct {
	ID   string `json:"id"`
	Key  string `json:"key"`
	Name string `json:"name"`
}

type v2Spaces struct {
	Results []v2Space `json:"results"`
	Links   links     `json:"_links"`
}

// v2Page is a page or blog post (single or list item).
type v2Page struct {
	ID        string    `json:"id"`
	Status    string    `json:"status"`
	Title     string    `json:"title"`
	AuthorID  string    `json:"authorId"`
	CreatedAt string    `json:"createdAt"`
	Version   v2Version `json:"version"`
	Body      v2Body    `json:"body"`
	Labels    struct {
		Results []struct {
			Name string `json:"name"`
		} `json:"results"`
	} `json:"labels"`
	Links links `json:"_links"`
}

type v2Pages struct {
	Results []v2Page `json:"results"`
	Links   links    `json:"_links"`
}

type v2Attachment struct {
	ID           string    `json:"id"`
	Status       string    `json:"status"`
	Title        string    `json:"title"`
	CreatedAt    string    `json:"createdAt"`
	PageID       string    `json:"pageId"`
	BlogPostID   string    `json:"blogPostId"`
	MediaType    string    `json:"mediaType"`
	FileSize     int64     `json:"fileSize"`
	WebUILink    string    `json:"webuiLink"`
	DownloadLink string    `json:"downloadLink"`
	Version      v2Version `json:"version"`
	Links        links     `json:"_links"`
}

// v2Comment is a footer or inline comment, top-level or a reply.
type v2Comment struct {
	ID               string    `json:"id"`
	Status           string    `json:"status"`
	Version          v2Version `json:"version"`
	Body             v2Body    `json:"body"`
	ResolutionStatus string    `json:"resolutionStatus"`
	Properties       struct {
		InlineOriginalSelection string `json:"inlineOriginalSelection"`
	} `json:"properties"`
}

type v2Comments struct {
	Results []v2Comment `json:"results"`
	Links   links       `json:"_links"`
}

// --- v1 users (/wiki/rest/api/user/bulk) ---

type bulkUsers struct {
	Results []struct {
		AccountID   string `json:"accountId"`
		PublicName  string `json:"publicName"`
		DisplayName string `json:"displayName"`
		Email       string `json:"email"`
	} `json:"results"`
}
