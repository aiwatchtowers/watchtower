package kb

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// extSource renders one document per ext_documents row of one external
// provider (Confluence today): pages and blog posts with their comments, and
// attachments with their extracted text. Refs are
// "<provider>:<ext_sources.id>:<ext_id>". The ext_* tables are source data
// written by internal/extsync; this adapter only reads them (KB-01).
// Changed lives in source_ext_changed.go.
type extSource struct {
	provider string
	// userLimit caps one Changed call's users-arm page; 0 = extUserPageSize.
	userLimit int
}

func (s extSource) Name() string { return s.provider }

// extMention matches a user-mention token in stored section/comment text —
// the "@[~<accountId>]" shape confluence.MentionPrefix produces. kb does not
// import internal/confluence (it stays free of fetchers), so the shape is
// matched here; internal/confluence's TestMentionTokenMatchesKBPattern pins
// the rendered token against this same pattern.
var extMention = regexp.MustCompile(`@\[~([^\]]+)\]`)

// Keys lists every stored document of the provider (reconciled every run).
func (s extSource) Keys(ctx context.Context, q Queryer) ([]string, error) {
	return queryStrings(ctx, q, `SELECT ? || ':' || d.source_id || ':' || d.ext_id
		FROM ext_documents d JOIN ext_sources s ON s.id = d.source_id WHERE s.provider = ?`,
		s.provider, s.provider)
}

// extRow is one ext_documents row joined with its source's space.
type extRow struct {
	sourceID, extID                               string
	kind, parentID, title, url, status, authorID  string
	modifiedAt, sectionsJSON, metaJSON, mediaType string
	extractStatus, spaceKey, spaceName            string
}

// storedSection is extsync.Section's JSON shape (kb does not import extsync).
type storedSection struct {
	Heading string `json:"heading"`
	Anchor  string `json:"anchor"`
	Text    string `json:"text"`
}

// parseKey splits "<provider>:<source_id>:<ext_id>"; ok is false for any
// other shape.
func (s extSource) parseKey(key string) (sourceID, extID string, ok bool) {
	rest, ok := splitRef(key, s.provider+":")
	if !ok {
		return "", "", false
	}
	sourceID, extID, found := strings.Cut(rest, ":")
	if !found || extID == "" {
		return "", "", false
	}
	if _, err := strconv.ParseInt(sourceID, 10, 64); err != nil {
		return "", "", false
	}
	return sourceID, extID, true
}

func (s extSource) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	sourceID, extID, ok := s.parseKey(key)
	if !ok {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}
	r := extRow{sourceID: sourceID, extID: extID}
	err := q.QueryRowContext(ctx, `SELECT d.kind, d.parent_ext_id, d.title, d.url, d.status, d.author_id,
		d.modified_at, d.sections_json, d.meta_json, d.media_type, d.extract_status, s.container_key, s.container_name
		FROM ext_documents d JOIN ext_sources s ON s.id = d.source_id
		WHERE d.source_id = ? AND d.ext_id = ? AND s.provider = ?`, sourceID, extID, s.provider).
		Scan(&r.kind, &r.parentID, &r.title, &r.url, &r.status, &r.authorID,
			&r.modifiedAt, &r.sectionsJSON, &r.metaJSON, &r.mediaType, &r.extractStatus, &r.spaceKey, &r.spaceName)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("kb %s %s: %w", s.provider, key, err)
	}
	names := &extNames{q: q, provider: s.provider, cache: map[string]string{}}
	doc := &Doc{
		ID:     key,
		Source: s.provider,
		Title:  r.title,
		Link:   r.url,
		Time:   parseTime(r.modifiedAt),
		Anchor: map[string]string{"source_id": sourceID, "ext_id": extID, "space": r.spaceKey},
	}
	if r.kind == "attachment" {
		err = s.fillAttachment(ctx, doc, &r, names)
	} else {
		err = s.fillPage(ctx, doc, &r, names)
	}
	if err != nil {
		return nil, fmt.Errorf("kb %s %s: %w", s.provider, key, err)
	}
	return doc, nil
}

// fillPage renders a page or blog post: its stored sections, then one
// section per comment.
func (s extSource) fillPage(ctx context.Context, doc *Doc, r *extRow, names *extNames) error {
	var meta map[string]string
	_ = json.Unmarshal([]byte(r.metaJSON), &meta)
	author, err := names.name(ctx, r.authorID)
	if err != nil {
		return err
	}
	parts := []string{r.spaceName, r.spaceKey, meta["ancestors"], meta["labels"], author}
	if r.status == "archived" {
		parts = append(parts, "archived")
	}
	inbound, err := discussedIn(ctx, names.q, r.sourceID, r.extID)
	if err != nil {
		return err
	}
	doc.Meta = joinNonEmpty(append(parts, inbound))
	if doc.Sections, err = s.storedSections(ctx, r, names); err != nil {
		return err
	}
	comments, err := s.commentSections(ctx, r, names)
	if err != nil {
		return err
	}
	doc.Sections = append(doc.Sections, comments...)
	return nil
}

// fillAttachment renders an attachment: its extracted text (none = the
// title-only rule of prepareDoc indexes the file name).
func (s extSource) fillAttachment(ctx context.Context, doc *Doc, r *extRow, names *extNames) error {
	var parentTitle string
	if r.parentID != "" {
		err := names.q.QueryRowContext(ctx, `SELECT title FROM ext_documents WHERE source_id = ? AND ext_id = ?`,
			r.sourceID, r.parentID).Scan(&parentTitle)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("parent title: %w", err)
		}
	}
	parts := []string{parentTitle, r.spaceName, r.spaceKey, r.mediaType}
	if r.extractStatus != "ok" {
		parts = append(parts, r.extractStatus)
	}
	doc.Meta = joinNonEmpty(parts)
	var err error
	doc.Sections, err = s.storedSections(ctx, r, names)
	return err
}

// storedSections maps sections_json; a heading anchor becomes a deep link
// into the page, anything else points at the document id.
func (s extSource) storedSections(ctx context.Context, r *extRow, names *extNames) ([]Section, error) {
	var stored []storedSection
	if err := json.Unmarshal([]byte(r.sectionsJSON), &stored); err != nil {
		// Unreadable sections render as none (title-only) rather than fail
		// the whole batch. Not logged: internal/kb has no logger (the
		// indexer reports only through Stats and returned errors), and
		// extsync always writes sections_json via json.Marshal, so this is
		// reachable only through a hand-edited row.
		return nil, nil //nolint:nilerr // see above
	}
	out := make([]Section, 0, len(stored))
	for _, st := range stored {
		text, err := names.resolve(ctx, st.Text)
		if err != nil {
			return nil, err
		}
		anchor := r.extID
		if st.Anchor != "" && r.url != "" {
			anchor = r.url + "#" + st.Anchor
		}
		out = append(out, Section{Text: text, Anchor: anchor})
	}
	return out, nil
}

// commentSections renders every comment of a page, oldest first:
// "<author>: <body>", inline "<author> on “<anchor>”: <body>", resolved
// suffixed " (resolved)", anchored at the comment's focused-comment link.
func (s extSource) commentSections(ctx context.Context, r *extRow, names *extNames) ([]Section, error) {
	// Loaded in full before any name lookup (single-connection rule).
	comments, err := loadExtComments(ctx, names.q, r.sourceID, r.extID)
	if err != nil {
		return nil, fmt.Errorf("comments: %w", err)
	}
	out := make([]Section, 0, len(comments))
	for _, c := range comments {
		text, err := c.render(ctx, names)
		if err != nil {
			return nil, err
		}
		out = append(out, Section{Text: text, Anchor: commentAnchor(r.url, c.id)})
	}
	return out, nil
}

// commentAnchor is the focused-comment deep link of comment id on a page at
// pageURL (the comment id alone without a URL). A URL that already carries a
// query (viewpage.action?pageId=…) gets the parameter appended with "&".
func commentAnchor(pageURL, id string) string {
	if pageURL == "" {
		return id
	}
	sep := "?"
	if strings.Contains(pageURL, "?") {
		sep = "&"
	}
	return pageURL + sep + "focusedCommentId=" + id
}

// extComment is one ext_comments row.
type extComment struct {
	id, kind, authorID, body, anchorText string
	resolved                             bool
}

func loadExtComments(ctx context.Context, q Queryer, sourceID, pageID string) ([]extComment, error) {
	rows, err := q.QueryContext(ctx, `SELECT ext_id, kind, author_id, body_text, anchor_text, resolved
		FROM ext_comments WHERE source_id = ? AND page_ext_id = ? ORDER BY created_at, ext_id`, sourceID, pageID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []extComment
	for rows.Next() {
		var c extComment
		if err := rows.Scan(&c.id, &c.kind, &c.authorID, &c.body, &c.anchorText, &c.resolved); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// render is "<author>: <body>", inline "<author> on “<anchor>”: <body>",
// suffixed " (resolved)" when resolved; an unknown author is "user".
func (c extComment) render(ctx context.Context, names *extNames) (string, error) {
	author, err := names.name(ctx, c.authorID)
	if err != nil {
		return "", err
	}
	if author == "" {
		author = "user"
	}
	body, err := names.resolve(ctx, c.body)
	if err != nil {
		return "", err
	}
	text := author + ": " + body
	if c.kind == "inline" && c.anchorText != "" {
		text = author + " on “" + c.anchorText + "”: " + body
	}
	if c.resolved {
		text += " (resolved)"
	}
	return text, nil
}

// extNames resolves provider user ids to display names from ext_users,
// cached per Build.
type extNames struct {
	q        Queryer
	provider string
	cache    map[string]string
}

// name returns id's display name, "" when unknown (or id is empty).
func (n *extNames) name(ctx context.Context, id string) (string, error) {
	if id == "" {
		return "", nil
	}
	if v, ok := n.cache[id]; ok {
		return v, nil
	}
	var name string
	err := n.q.QueryRowContext(ctx, `SELECT display_name FROM ext_users WHERE provider = ? AND ext_user_id = ?`,
		n.provider, id).Scan(&name)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", fmt.Errorf("user %s: %w", id, err)
	}
	n.cache[id] = name
	return name, nil
}

// resolve replaces every mention token with "@<display name>" ("@user"
// when the id is unknown).
func (n *extNames) resolve(ctx context.Context, text string) (string, error) {
	var firstErr error
	out := extMention.ReplaceAllStringFunc(text, func(m string) string {
		name, err := n.name(ctx, extMention.FindStringSubmatch(m)[1])
		if err != nil && firstErr == nil {
			firstErr = err
		}
		if name == "" {
			name = "user"
		}
		return "@" + name
	})
	return out, firstErr
}

func joinNonEmpty(parts []string) string {
	var out []string
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return strings.Join(out, " ")
}
