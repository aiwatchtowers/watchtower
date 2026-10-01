package tools

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/extsync"
	"watchtower/internal/jira"
)

// ConfluenceREST is the slice of *jira.ConfluenceAPI the page client uses.
// This file holds the only production call of PutJSON (EXT-05,
// TestEXT05_OnlyEditToolReachesPut): the sync path's confluence.API seam
// has no write method at all (EXT-01).
type ConfluenceREST interface {
	GetJSON(ctx context.Context, path string, q url.Values, out any) error
	PutJSON(ctx context.Context, path string, body any, out any) error
}

// ConfluenceCommentSource is the slice of *confluence.Fetcher the page
// client reuses for comments and user names, so the REST parsing of both
// lives in one place (internal/confluence).
type ConfluenceCommentSource interface {
	Comments(ctx context.Context, c extsync.Container, pageID string) ([]extsync.Item, error)
	Users(ctx context.Context, ids []string) (map[string]extsync.User, error)
}

// ConfluencePage is one live page or blog post in storage format.
type ConfluencePage struct {
	ID       string
	Kind     string // "page" | "blogpost"
	Status   string // "current" | "archived" (Confluence's v2 status)
	Title    string
	SpaceKey string
	URL      string
	Version  int
	Storage  string
}

// archived reports whether the page is archived. edit_confluence_page
// never writes one: its PUT carries status "current", which would restore
// the page as a side effect nobody approved.
func (p ConfluencePage) archived() bool { return p.Status == "archived" }

// ConfluenceComment is one footer or inline comment of a page; ReplyTo is
// the id of the comment it answers ("" = top-level).
type ConfluenceComment struct {
	ID               string
	ReplyTo          string
	AuthorID         string
	Created          time.Time
	Kind             string // "footer" | "inline"
	AnchorText       string
	Resolved         bool
	Body             string
	MentionedUserIDs []string
}

// ConfluencePutBody is the v2 page/blog post update request.
// https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-page/#api-pages-id-put
type ConfluencePutBody struct {
	ID      string                   `json:"id"`
	Status  string                   `json:"status"`
	Title   string                   `json:"title"`
	Body    ConfluencePutStorage     `json:"body"`
	Version ConfluencePutVersionInfo `json:"version"`
}

// ConfluencePutStorage is the body of a ConfluencePutBody.
type ConfluencePutStorage struct {
	Representation string `json:"representation"`
	Value          string `json:"value"`
}

// ConfluencePutVersionInfo is the version of a ConfluencePutBody.
type ConfluencePutVersionInfo struct {
	Number  int    `json:"number"`
	Message string `json:"message"`
}

// ConfluencePageClient is what the two Confluence page tools need from one
// connected account (tests inject a fake).
type ConfluencePageClient interface {
	GetPage(ctx context.Context, id string) (ConfluencePage, error)
	// GetPageBody is GetPage without the display-only space key (one GET
	// fewer): what the edit tool reads at propose and apply time.
	GetPageBody(ctx context.Context, id string) (ConfluencePage, error)
	// PutPage writes body as the page's next version and returns the new
	// version number. Only edit_confluence_page's Execute calls it.
	PutPage(ctx context.Context, id, kind string, body ConfluencePutBody) (int, error)
	Comments(ctx context.Context, id string) ([]ConfluenceComment, error)
	// Users maps account ids to display names; an id Confluence does not
	// return is absent.
	Users(ctx context.Context, ids []string) (map[string]string, error)
	// HasReadScopes / HasWriteScopes report the account grant's Confluence
	// read and (opt-in) write scopes; each tool turns a missing one into its
	// own re-consent hint.
	HasReadScopes() bool
	HasWriteScopes() bool
}

// ConfluencePageClientFactory builds a page client for one connected account.
type ConfluencePageClientFactory func(account db.JiraAccount) (ConfluencePageClient, error)

// errConfluencePageNotFound: neither the page nor the blog post collection
// knows the id (deleted, never existed, or invisible to the account).
var errConfluencePageNotFound = errors.New("confluence page not found")

const confluenceV2 = "/wiki/api/v2"

// confluencePageClient implements ConfluencePageClient over the account's
// shared Atlassian grant.
type confluencePageClient struct {
	api      ConfluenceREST
	comments ConfluenceCommentSource
	siteURL  string
	canRead  bool
	canWrite bool
}

// NewConfluencePageClient builds the live client: api for the page itself
// (GET, and the PUT of an approved edit), comments for the comment and
// user listings. siteURL prefixes the page's web link; canRead/canWrite are
// the grant's Confluence read and write scopes.
func NewConfluencePageClient(api ConfluenceREST, comments ConfluenceCommentSource, siteURL string, canRead, canWrite bool) ConfluencePageClient {
	return &confluencePageClient{api: api, comments: comments, siteURL: strings.TrimRight(siteURL, "/"),
		canRead: canRead, canWrite: canWrite}
}

func (c *confluencePageClient) HasReadScopes() bool  { return c.canRead }
func (c *confluencePageClient) HasWriteScopes() bool { return c.canWrite }

func confluenceCollection(kind string) string {
	if kind == "blogpost" {
		return "/blogposts/"
	}
	return "/pages/"
}

type confluenceV2Page struct {
	ID      string `json:"id"`
	Status  string `json:"status"`
	Title   string `json:"title"`
	SpaceID string `json:"spaceId"`
	Version struct {
		Number int `json:"number"`
	} `json:"version"`
	Body struct {
		Storage struct {
			Value string `json:"value"`
		} `json:"storage"`
	} `json:"body"`
	Links struct {
		WebUI string `json:"webui"`
	} `json:"_links"`
}

// GetPage fetches id as a page, then as a blog post. An archived page is
// fetched too (status=current,archived, as the sync fetcher asks): without
// an explicit status only current pages are returned, and a page search
// finds would read as "not found".
func (c *confluencePageClient) GetPage(ctx context.Context, id string) (ConfluencePage, error) {
	return c.getPage(ctx, id, true)
}

// GetPageBody fetches id like GetPage, leaving SpaceKey empty.
func (c *confluencePageClient) GetPageBody(ctx context.Context, id string) (ConfluencePage, error) {
	return c.getPage(ctx, id, false)
}

func (c *confluencePageClient) getPage(ctx context.Context, id string, withSpace bool) (ConfluencePage, error) {
	for _, kind := range []string{"page", "blogpost"} {
		var p confluenceV2Page
		q := url.Values{"body-format": {"storage"}}
		if kind == "page" {
			q["status"] = []string{"current", "archived"}
		}
		err := c.api.GetJSON(ctx, confluenceV2+confluenceCollection(kind)+url.PathEscape(id), q, &p)
		if httpStatus(err) == 404 {
			continue
		}
		if err != nil {
			return ConfluencePage{}, err
		}
		page := ConfluencePage{ID: p.ID, Kind: kind, Status: p.Status, Title: p.Title, Version: p.Version.Number, Storage: p.Body.Storage.Value}
		if withSpace {
			page.SpaceKey = c.spaceKey(ctx, p.SpaceID)
		}
		if p.Links.WebUI != "" {
			page.URL = c.siteURL + "/wiki" + p.Links.WebUI
		}
		return page, nil
	}
	return ConfluencePage{}, errConfluencePageNotFound
}

// spaceKey resolves a v2 space id to its key; best-effort ("" on failure —
// the key is display-only).
func (c *confluencePageClient) spaceKey(ctx context.Context, spaceID string) string {
	if spaceID == "" {
		return ""
	}
	var s struct {
		Key string `json:"key"`
	}
	if err := c.api.GetJSON(ctx, confluenceV2+"/spaces/"+url.PathEscape(spaceID), nil, &s); err != nil {
		return ""
	}
	return s.Key
}

// PutPage issues the one PUT an approved edit makes.
func (c *confluencePageClient) PutPage(ctx context.Context, id, kind string, body ConfluencePutBody) (int, error) {
	var out struct {
		Version struct {
			Number int `json:"number"`
		} `json:"version"`
	}
	if err := c.api.PutJSON(ctx, confluenceV2+confluenceCollection(kind)+url.PathEscape(id), body, &out); err != nil {
		return 0, err
	}
	if out.Version.Number == 0 {
		return 0, fmt.Errorf("confluence answered the update of %s without a version number", id)
	}
	return out.Version.Number, nil
}

// Comments lists every comment of the page through the fetcher.
func (c *confluencePageClient) Comments(ctx context.Context, id string) ([]ConfluenceComment, error) {
	items, err := c.comments.Comments(ctx, extsync.Container{}, id)
	if err != nil {
		return nil, err
	}
	out := make([]ConfluenceComment, 0, len(items))
	for _, it := range items {
		var body []string
		for _, s := range it.Sections {
			body = append(body, s.Text)
		}
		out = append(out, ConfluenceComment{ID: it.Ref.ExtID, ReplyTo: it.ReplyTo, AuthorID: it.AuthorID,
			Created: it.Created, Kind: it.CommentKind, AnchorText: it.AnchorText, Resolved: it.Resolved,
			Body: strings.Join(body, "\n\n"), MentionedUserIDs: it.MentionedUserIDs})
	}
	return out, nil
}

// Users resolves display names through the fetcher.
func (c *confluencePageClient) Users(ctx context.Context, ids []string) (map[string]string, error) {
	users, err := c.comments.Users(ctx, ids)
	if err != nil {
		return nil, err
	}
	out := make(map[string]string, len(users))
	for id, u := range users {
		if u.DisplayName != "" {
			out[id] = u.DisplayName
		}
	}
	return out, nil
}

// httpStatus is the status of an *jira.HTTPStatusError in err's chain, 0
// for any other error (or none).
func httpStatus(err error) int {
	var he *jira.HTTPStatusError
	if errors.As(err, &he) {
		return he.Status
	}
	return 0
}
