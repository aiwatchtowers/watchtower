package confluence

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"strings"
	"sync"
	"time"

	"watchtower/internal/extsync"
	"watchtower/internal/jira"
)

// Fetcher implements extsync.Fetcher over the Confluence Cloud REST API
// (spec §6). It issues GET requests only, through API (EXT-01).
//
// Endpoint choice: the v1 CQL search (/wiki/rest/api/content/search) is the
// only delta enumeration Confluence offers, so Changed and the attachment
// All use it. Everything else uses the v2 API: the v1 single-content and
// child-comment endpoints are no longer in Atlassian's published v1 spec.
// Every listing pages by cursor (_links.next), never by offset.
type Fetcher struct {
	api     API
	siteURL string
	// kinds maps a page/blog post id to its kind, learned from listings and
	// fetches, so Comments knows which v2 collection a parent lives in.
	kinds sync.Map
}

var _ extsync.Fetcher = (*Fetcher)(nil)

// NewFetcher returns a Fetcher reading through api; siteURL
// ("https://acme.atlassian.net") prefixes the web links of fetched items.
func NewFetcher(api API, siteURL string) *Fetcher {
	return &Fetcher{api: api, siteURL: strings.TrimRight(siteURL, "/")}
}

const (
	// pageSize is the enumeration page size (global constraint).
	pageSize = 100
	// spacesPageSize is the page size of the space picker listing (the v2
	// maximum).
	spacesPageSize = 250
	// cqlOverlap is subtracted from since in CQL: CQL reads its date in the
	// requesting user's time zone, which the fetcher does not know, and a
	// day covers every zone. The engine's version gate makes the extra rows
	// cost enumeration only.
	cqlOverlap = 24 * time.Hour
	// cqlTimeLayout is CQL's "yyyy/MM/dd HH:mm".
	cqlTimeLayout = "2006/01/02 15:04"
	// maxBodyRunes caps a page body (global constraint).
	maxBodyRunes = 1_000_000
	// usersPerCall is the user/bulk limit.
	usersPerCall = 100

	searchPath = "/wiki/rest/api/content/search"
	v2Root     = "/wiki/api/v2"
)

// get performs one GET and maps its error (R1).
func (f *Fetcher) get(ctx context.Context, path string, q url.Values, out any) error {
	return mapErr(f.api.GetJSON(ctx, path, q, out))
}

// Containers lists the spaces the account can see (for the picker).
// https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-space/#api-spaces-get
func (f *Fetcher) Containers(ctx context.Context) ([]extsync.Container, error) {
	var out []extsync.Container
	cursor := ""
	for {
		q := url.Values{"limit": {fmt.Sprint(spacesPageSize)}}
		if cursor != "" {
			q.Set("cursor", cursor)
		}
		var res v2Spaces
		if err := f.get(ctx, v2Root+"/spaces", q, &res); err != nil {
			return nil, fmt.Errorf("confluence: listing spaces: %w", err)
		}
		for _, s := range res.Results {
			out = append(out, extsync.Container{Key: s.Key, Name: s.Name, ExtID: s.ID})
		}
		next, err := nextCursor(res.Links.Next)
		if err != nil || next == "" {
			return out, err
		}
		cursor = next
	}
}

// Changed lists the refs of kind modified at or after since, through CQL.
// Contract (the engine relies on it):
//   - ascending by Modified (ORDER BY lastmodified ASC);
//   - since is widened by cqlOverlap (24 h) for CQL's time-zone blindness; a
//     zero since omits the date clause;
//   - KindPage lists pages and blog posts together; ParentID is set for
//     comments and attachments (their container);
//   - KindComment lists only comments on a page or blog post — footer and
//     inline, replies at any depth — i.e. exactly what Comments returns for
//     that parent, with the same Version;
//   - trashed content is never listed; archived content is not listed
//     either (CQL search does not return it — see All);
//   - page is the cursor of the previous call's next link ("" = first);
//     a rejected cursor is an error, never an empty page.
func (f *Fetcher) Changed(ctx context.Context, c extsync.Container, kind extsync.ItemKind, since time.Time, page string) ([]extsync.ItemRef, string, error) {
	return f.searchRefs(ctx, c, kind, since, page)
}

// All enumerates every visible id of kind (the daily reconcile). It covers
// Changed: every ref Changed can list is also listed here, with the same
// version, so a reconcile never deletes what the delta just wrote. Pages are
// enumerated from the v2 space listing, which — unlike CQL — includes
// archived pages, so an archived page stays; blog posts follow in a second
// phase (tokens "p:<cursor>" / "b:<cursor>"). Other kinds use Changed's CQL
// without the date clause. Trashed content is excluded everywhere.
func (f *Fetcher) All(ctx context.Context, c extsync.Container, kind extsync.ItemKind, page string) ([]extsync.ItemRef, string, error) {
	if kind == extsync.KindPage {
		return f.allPages(ctx, c, page)
	}
	return f.searchRefs(ctx, c, kind, time.Time{}, page)
}

// Fetch returns one page, blog post or attachment; nil, nil when it is gone
// (404, or trashed). Comments are never fetched one by one — see Comments.
func (f *Fetcher) Fetch(ctx context.Context, c extsync.Container, ref extsync.ItemRef) (*extsync.Item, error) {
	switch ref.Kind {
	case extsync.KindPage, extsync.KindBlogpost:
		return f.fetchPage(ctx, c, ref)
	case extsync.KindAttachment:
		return f.fetchAttachment(ctx, c, ref)
	case extsync.KindComment:
		return nil, fmt.Errorf("confluence: comment %s is fetched with its page (Comments), never alone", ref.ExtID)
	}
	return nil, fmt.Errorf("confluence: fetch of unsupported kind %q", ref.Kind)
}

// Download opens an attachment's bytes, capped at limit. Errors follow the
// extsync.Fetcher contract: a 404 (the attachment was deleted since Fetch)
// is extsync.ErrGone, and jira.ErrTooLarge — upfront, or from a Read of the
// returned body — also matches extsync.ErrTooLarge.
func (f *Fetcher) Download(ctx context.Context, it *extsync.Item, limit int64) (io.ReadCloser, error) {
	if it.Download == "" {
		return nil, fmt.Errorf("confluence: item %s has no download path", it.Ref.ExtID)
	}
	rc, err := f.api.Download(ctx, it.Download, limit)
	if err != nil {
		return nil, mapDownloadErr(err)
	}
	return &downloadBody{rc: rc}, nil
}

// mapDownloadErr is mapErr plus the download outcomes: 404 → gone, the
// size cap → too large. The original error stays in the chain.
func mapDownloadErr(err error) error {
	switch {
	case isNotFound(err):
		return fmt.Errorf("%w: %w", extsync.ErrGone, err)
	case errors.Is(err, jira.ErrTooLarge):
		return fmt.Errorf("%w: %w", extsync.ErrTooLarge, err)
	}
	return mapErr(err)
}

// downloadBody maps a read-time jira.ErrTooLarge onto extsync.ErrTooLarge;
// io.EOF and other errors pass through unchanged.
type downloadBody struct{ rc io.ReadCloser }

func (b *downloadBody) Read(p []byte) (int, error) {
	n, err := b.rc.Read(p)
	if err != nil && errors.Is(err, jira.ErrTooLarge) {
		err = fmt.Errorf("%w: %w", extsync.ErrTooLarge, err)
	}
	return n, err
}

func (b *downloadBody) Close() error { return b.rc.Close() }

// Users resolves account ids in batches of usersPerCall. An id Confluence
// does not return is absent from the map.
// https://developer.atlassian.com/cloud/confluence/rest/v1/api-group-users/#api-wiki-rest-api-user-bulk-get
func (f *Fetcher) Users(ctx context.Context, ids []string) (map[string]extsync.User, error) {
	out := make(map[string]extsync.User, len(ids))
	for start := 0; start < len(ids); start += usersPerCall {
		batch := ids[start:min(start+usersPerCall, len(ids))]
		var res bulkUsers
		if err := f.get(ctx, "/wiki/rest/api/user/bulk", url.Values{"accountId": batch}, &res); err != nil {
			return nil, fmt.Errorf("confluence: resolving users: %w", err)
		}
		for _, u := range res.Results {
			name := u.PublicName
			if name == "" {
				name = u.DisplayName
			}
			out[u.AccountID] = extsync.User{ID: u.AccountID, DisplayName: name, Email: u.Email}
		}
	}
	return out, nil
}

// --- CQL enumeration ---

// buildCQL renders the delta/enumeration CQL for kind in spaceKey. A
// non-zero since becomes a lastmodified clause widened by cqlOverlap and
// rendered in UTC.
func buildCQL(spaceKey string, kind extsync.ItemKind, since time.Time) (string, error) {
	var typ string
	switch kind {
	case extsync.KindPage:
		typ = "type IN (page, blogpost)"
	case extsync.KindComment:
		typ = "type = comment"
	case extsync.KindAttachment:
		typ = "type = attachment"
	default:
		return "", fmt.Errorf("confluence: cannot enumerate kind %q", kind)
	}
	clauses := []string{fmt.Sprintf("space = %s", cqlQuote(spaceKey)), typ}
	if !since.IsZero() {
		from := since.UTC().Add(-cqlOverlap).Format(cqlTimeLayout)
		clauses = append(clauses, fmt.Sprintf("lastmodified >= %q", from))
	}
	return strings.Join(clauses, " AND ") + " ORDER BY lastmodified ASC", nil
}

// cqlQuote renders s as a double-quoted CQL string.
func cqlQuote(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`)
	return `"` + r.Replace(s) + `"`
}

// search runs one CQL search page.
// https://developer.atlassian.com/cloud/confluence/rest/v1/api-group-content/#api-wiki-rest-api-content-search-get
func (f *Fetcher) search(ctx context.Context, cql, expand, cursor string) (searchResponse, string, error) {
	q := url.Values{"cql": {cql}, "limit": {fmt.Sprint(pageSize)}}
	if expand != "" {
		q.Set("expand", expand)
	}
	if cursor != "" {
		q.Set("cursor", cursor)
	}
	var res searchResponse
	if err := f.get(ctx, searchPath, q, &res); err != nil {
		return searchResponse{}, "", fmt.Errorf("confluence: searching %q: %w", cql, err)
	}
	next, err := nextCursor(res.Links.Next)
	if err != nil {
		return searchResponse{}, "", err
	}
	return res, next, nil
}

// searchRefs lists one CQL page of kind as refs.
func (f *Fetcher) searchRefs(ctx context.Context, c extsync.Container, kind extsync.ItemKind, since time.Time, page string) ([]extsync.ItemRef, string, error) {
	cql, err := buildCQL(c.Key, kind, since)
	if err != nil {
		return nil, "", err
	}
	res, next, err := f.search(ctx, cql, "version,container", page)
	if err != nil {
		return nil, "", err
	}
	refs := make([]extsync.ItemRef, 0, len(res.Results))
	for i := range res.Results {
		ref, ok, err := f.searchRef(&res.Results[i])
		if err != nil {
			return nil, "", err
		}
		if ok {
			refs = append(refs, ref)
		}
	}
	return refs, next, nil
}

// searchRef maps one search result; ok is false for a row the fetcher does
// not list (trashed, an unknown type, a comment not on a page/blog post).
func (f *Fetcher) searchRef(r *searchContent) (extsync.ItemRef, bool, error) {
	kind, ok := searchKinds[r.Type]
	if !ok || !visible(r.Status) {
		return extsync.ItemRef{}, false, nil
	}
	modified, err := parseTime(r.Version.When)
	if err != nil {
		return extsync.ItemRef{}, false, err
	}
	ref := extsync.ItemRef{Kind: kind, ExtID: r.ID, Version: r.Version.Number, Modified: modified}
	switch kind {
	case extsync.KindPage, extsync.KindBlogpost:
		f.learn(r.ID, kind)
	case extsync.KindComment, extsync.KindAttachment:
		parentKind, isParent := searchKinds[r.Container.Type]
		if !isParent || (parentKind != extsync.KindPage && parentKind != extsync.KindBlogpost) {
			// Comments() lists page/blog post comments only; an attachment
			// without a page parent has no parent to hang off either.
			return extsync.ItemRef{}, false, nil
		}
		ref.ParentID = string(r.Container.ID)
		f.learn(ref.ParentID, parentKind)
	}
	return ref, true, nil
}

// searchKinds maps a v1 content type to its kind.
var searchKinds = map[string]extsync.ItemKind{
	"page":       extsync.KindPage,
	"blogpost":   extsync.KindBlogpost,
	"comment":    extsync.KindComment,
	"attachment": extsync.KindAttachment,
}

// visible reports whether a content status is one the fetcher lists:
// current or archived. Trashed, deleted, draft and historical are not.
func visible(status string) bool {
	return status == "current" || status == "archived"
}

func (f *Fetcher) learn(id string, kind extsync.ItemKind) {
	if id != "" {
		f.kinds.Store(id, kind)
	}
}

// --- v2 page enumeration (All) ---

// allPages enumerates the space's pages (current + archived) and then its
// blog posts.
// https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-page/#api-spaces-id-pages-get
// https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-blog-post/#api-spaces-id-blogposts-get
func (f *Fetcher) allPages(ctx context.Context, c extsync.Container, token string) ([]extsync.ItemRef, string, error) {
	if c.ExtID == "" {
		return nil, "", fmt.Errorf("confluence: space %q has no id", c.Key)
	}
	phase, cursor, err := parsePhaseToken(token)
	if err != nil {
		return nil, "", err
	}
	kind, path, q := extsync.KindPage, "/pages", url.Values{"depth": {"all"}, "status": {"current", "archived"}}
	if phase == "b" {
		kind, path, q = extsync.KindBlogpost, "/blogposts", url.Values{"status": {"current"}}
	}
	q.Set("limit", fmt.Sprint(pageSize))
	if cursor != "" {
		q.Set("cursor", cursor)
	}
	var res v2Pages
	if err := f.get(ctx, v2Root+"/spaces/"+url.PathEscape(c.ExtID)+path, q, &res); err != nil {
		return nil, "", fmt.Errorf("confluence: enumerating %s: %w", kind, err)
	}
	refs, err := f.pageRefs(res.Results, kind)
	if err != nil {
		return nil, "", err
	}
	next, err := nextCursor(res.Links.Next)
	switch {
	case err != nil:
		return nil, "", err
	case next != "":
		return refs, phase + ":" + next, nil
	case phase == "p":
		return refs, "b:", nil
	}
	return refs, "", nil
}

// parsePhaseToken splits an allPages token into its phase ("p" pages, "b"
// blog posts) and cursor; "" is the first pages call.
func parsePhaseToken(token string) (phase, cursor string, err error) {
	if token == "" {
		return "p", "", nil
	}
	phase, cursor, found := strings.Cut(token, ":")
	if !found || (phase != "p" && phase != "b") {
		return "", "", fmt.Errorf("confluence: bad enumeration token %q", token)
	}
	return phase, cursor, nil
}

// pageRefs maps visible v2 pages or blog posts to refs.
func (f *Fetcher) pageRefs(pages []v2Page, kind extsync.ItemKind) ([]extsync.ItemRef, error) {
	refs := make([]extsync.ItemRef, 0, len(pages))
	for _, p := range pages {
		if !visible(p.Status) {
			continue
		}
		modified, err := parseTime(p.Version.CreatedAt)
		if err != nil {
			return nil, err
		}
		f.learn(p.ID, kind)
		refs = append(refs, extsync.ItemRef{Kind: kind, ExtID: p.ID, Version: p.Version.Number, Modified: modified})
	}
	return refs, nil
}

// --- Fetch ---

// fetchPage fetches a page or blog post in storage format.
// https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-page/#api-pages-id-get
// https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-blog-post/#api-blogposts-id-get
func (f *Fetcher) fetchPage(ctx context.Context, c extsync.Container, ref extsync.ItemRef) (*extsync.Item, error) {
	q := url.Values{"body-format": {"storage"}, "include-labels": {"true"}}
	collection := "/blogposts/"
	if ref.Kind == extsync.KindPage {
		collection = "/pages/"
		// Without an explicit status only current pages are guaranteed;
		// an archived page must be fetched, not reported gone.
		q["status"] = []string{"current", "archived"}
	}
	var p v2Page
	if err := f.get(ctx, v2Root+collection+url.PathEscape(ref.ExtID), q, &p); err != nil {
		if isNotFound(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("confluence: fetching %s %s: %w", ref.Kind, ref.ExtID, err)
	}
	if !visible(p.Status) {
		return nil, nil
	}
	f.learn(p.ID, ref.Kind)
	it, err := f.pageItem(c, ref, &p)
	if err != nil {
		return nil, err
	}
	if ref.Kind == extsync.KindPage {
		path, err := f.ancestors(ctx, p.ID)
		if err != nil {
			return nil, err
		}
		if path != "" {
			it.Meta["ancestors"] = path
		}
	}
	return it, nil
}

// pageItem maps a fetched page or blog post.
func (f *Fetcher) pageItem(c extsync.Container, ref extsync.ItemRef, p *v2Page) (*extsync.Item, error) {
	modified, err := parseTime(p.Version.CreatedAt)
	if err != nil {
		return nil, err
	}
	created, err := parseOptionalTime(p.CreatedAt)
	if err != nil {
		return nil, err
	}
	sections, users, keys := StorageToSections(p.Body.Storage.Value, maxBodyRunes)
	meta := map[string]string{"space": c.Key, "status": p.Status}
	labels := make([]string, 0, len(p.Labels.Results))
	for _, l := range p.Labels.Results {
		labels = append(labels, l.Name)
	}
	setNonEmpty(meta, "labels", strings.Join(labels, ", "))
	setNonEmpty(meta, "jira_keys", strings.Join(keys, ","))
	return &extsync.Item{
		Ref:              extsync.ItemRef{Kind: ref.Kind, ExtID: p.ID, Version: p.Version.Number, Modified: modified, ParentID: ref.ParentID},
		Title:            p.Title,
		URL:              f.webURL(p.Links.WebUI),
		AuthorID:         p.AuthorID,
		Created:          created,
		Status:           p.Status,
		Sections:         sections,
		Meta:             meta,
		MentionedUserIDs: users,
	}, nil
}

func setNonEmpty(m map[string]string, k, v string) {
	if v != "" {
		m[k] = v
	}
}

// webURL turns a relative webui link into an absolute one.
func (f *Fetcher) webURL(webui string) string {
	if webui == "" {
		return ""
	}
	return f.siteURL + "/wiki" + webui
}

// ancestors returns a page's ancestor titles joined root-first with " / ".
// v2 exposes ancestor ids only (and under a scope the grant does not ask
// for), so this is one CQL search with expand=ancestors.
func (f *Fetcher) ancestors(ctx context.Context, id string) (string, error) {
	r, err := f.lookup(ctx, id, "ancestors")
	if err != nil || r == nil {
		return "", err
	}
	titles := make([]string, 0, len(r.Ancestors))
	for _, a := range r.Ancestors {
		titles = append(titles, a.Title)
	}
	return strings.Join(titles, " / "), nil
}

// lookup finds one content item by id through CQL; nil when search does
// not return it.
func (f *Fetcher) lookup(ctx context.Context, id, expand string) (*searchContent, error) {
	if !isNumericID(id) {
		return nil, fmt.Errorf("confluence: bad content id %q", id)
	}
	res, _, err := f.search(ctx, "id = "+id, expand, "")
	if err != nil || len(res.Results) == 0 {
		return nil, err
	}
	return &res.Results[0], nil
}

// isNumericID reports whether id is a plain decimal content id, the only
// shape interpolated into CQL unquoted.
func isNumericID(id string) bool {
	if id == "" {
		return false
	}
	for _, r := range id {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// fetchAttachment fetches an attachment's metadata; its bytes come later
// through Download.
// https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-attachment/#api-attachments-id-get
func (f *Fetcher) fetchAttachment(ctx context.Context, c extsync.Container, ref extsync.ItemRef) (*extsync.Item, error) {
	var a v2Attachment
	if err := f.get(ctx, v2Root+"/attachments/"+url.PathEscape(ref.ExtID), nil, &a); err != nil {
		if isNotFound(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("confluence: fetching attachment %s: %w", ref.ExtID, err)
	}
	if !visible(a.Status) {
		return nil, nil
	}
	modified, err := parseTime(a.Version.CreatedAt)
	if err != nil {
		return nil, err
	}
	created, err := parseOptionalTime(a.CreatedAt)
	if err != nil {
		return nil, err
	}
	parent := firstNonEmpty(a.PageID, a.BlogPostID, ref.ParentID)
	return &extsync.Item{
		Ref:       extsync.ItemRef{Kind: extsync.KindAttachment, ExtID: a.ID, Version: a.Version.Number, Modified: modified, ParentID: parent},
		Title:     a.Title,
		URL:       f.webURL(firstNonEmpty(a.Links.WebUI, a.WebUILink)),
		AuthorID:  a.Version.AuthorID,
		Created:   created,
		Status:    a.Status,
		Meta:      map[string]string{"space": c.Key, "status": a.Status},
		Download:  downloadPath(parent, a.ID),
		MediaType: a.MediaType,
		Size:      a.FileSize,
	}, nil
}

// downloadPath is the documented OAuth download endpoint of an attachment
// ("" without a parent).
// https://developer.atlassian.com/cloud/confluence/rest/v1/api-group-content---attachments/#api-wiki-rest-api-content-id-child-attachment-attachmentid-download-get
func downloadPath(parentID, attachmentID string) string {
	if parentID == "" {
		return ""
	}
	return "/wiki/rest/api/content/" + url.PathEscape(parentID) + "/child/attachment/" + url.PathEscape(attachmentID) + "/download"
}

func firstNonEmpty(vs ...string) string {
	for _, v := range vs {
		if v != "" {
			return v
		}
	}
	return ""
}
