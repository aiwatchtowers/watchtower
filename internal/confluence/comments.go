package confluence

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"

	"watchtower/internal/extsync"
)

// Comment locations (Item.CommentKind).
const (
	locationFooter = "footer"
	locationInline = "inline"
)

// maxReplyDepth bounds the reply walk: a thread nested deeper is an error,
// never an unbounded recursion.
const maxReplyDepth = 50

// inlineResolutionStatuses is every inline-comment resolution state; asked
// for explicitly so a resolved thread is never filtered out by a default.
var inlineResolutionStatuses = []string{"open", "reopened", "resolved", "dangling"}

// Comments returns the full comment set of one page or blog post: footer and
// inline comments with their replies at any depth, each as one section.
// CommentKind is "footer" or "inline" (a reply keeps its thread's); a reply
// to an inline comment inherits the thread's AnchorText and Resolved when it
// carries none of its own. Ref.Version is the comment's version number, the
// same number Changed(KindComment) reports. A parent search no longer finds
// (gone, or not a page/blog post) has no comments: nil, nil.
// https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-comment/
func (f *Fetcher) Comments(ctx context.Context, _ extsync.Container, pageID string) ([]extsync.Item, error) {
	kind, err := f.parentKind(ctx, pageID)
	if err != nil || kind == "" {
		return nil, err
	}
	collection := "/pages/"
	if kind == extsync.KindBlogpost {
		collection = "/blogposts/"
	}
	base := v2Root + collection + url.PathEscape(pageID)
	var out []extsync.Item
	seen := map[string]bool{}
	for _, loc := range []string{locationFooter, locationInline} {
		q := url.Values{}
		if loc == locationInline {
			q["resolution-status"] = inlineResolutionStatuses
		}
		roots, err := f.listComments(ctx, base+"/"+loc+"-comments", q)
		if errors.Is(err, errNotFound) {
			return nil, nil
		}
		if err != nil {
			return nil, err
		}
		for i := range roots {
			thread, err := f.commentThread(ctx, seen, loc, pageID, &roots[i], nil, 0)
			if err != nil {
				return nil, err
			}
			out = append(out, thread...)
		}
	}
	return out, nil
}

// parentKind returns whether id is a page or a blog post: from what
// listings and fetches taught the fetcher, else one CQL lookup. "" = not
// found, or neither.
func (f *Fetcher) parentKind(ctx context.Context, id string) (extsync.ItemKind, error) {
	if v, ok := f.kinds.Load(id); ok {
		return v.(extsync.ItemKind), nil
	}
	r, err := f.lookup(ctx, id, "")
	if err != nil || r == nil {
		return "", err
	}
	kind := searchKinds[r.Type]
	if kind != extsync.KindPage && kind != extsync.KindBlogpost {
		return "", nil
	}
	f.learn(id, kind)
	return kind, nil
}

// commentThread maps c and, depth-first, every reply under it. depth is
// c's reply depth (0 = top-level); seen holds every comment id already
// walked on this page. A repeated id (a cycle, or a comment listed twice) or
// a thread deeper than maxReplyDepth is an error, never a further recursion.
func (f *Fetcher) commentThread(ctx context.Context, seen map[string]bool, loc, pageID string, c *v2Comment, parent *extsync.Item, depth int) ([]extsync.Item, error) {
	if depth > maxReplyDepth {
		return nil, fmt.Errorf("confluence: comment %s on %s is nested deeper than %d replies", c.ID, pageID, maxReplyDepth)
	}
	if seen[c.ID] {
		return nil, fmt.Errorf("confluence: comment %s on %s listed twice (reply cycle?)", c.ID, pageID)
	}
	seen[c.ID] = true
	it, err := commentItem(loc, pageID, c, parent)
	if err != nil {
		return nil, err
	}
	out := []extsync.Item{it}
	replies, err := f.listComments(ctx, v2Root+"/"+loc+"-comments/"+url.PathEscape(c.ID)+"/children", url.Values{})
	if errors.Is(err, errNotFound) {
		// The comment was deleted while the thread was being walked.
		return out, nil
	}
	if err != nil {
		return nil, err
	}
	for i := range replies {
		sub, err := f.commentThread(ctx, seen, loc, pageID, &replies[i], &it, depth+1)
		if err != nil {
			return nil, err
		}
		out = append(out, sub...)
	}
	return out, nil
}

// listComments drains one v2 comment listing (storage bodies). A 404 on the
// first, cursor-less call is errNotFound; any failure on a call that
// carried a cursor is an error (R8).
func (f *Fetcher) listComments(ctx context.Context, path string, q url.Values) ([]v2Comment, error) {
	q.Set("body-format", "storage")
	q.Set("limit", fmt.Sprint(pageSize))
	var out []v2Comment
	cursor := ""
	for {
		if cursor != "" {
			q.Set("cursor", cursor)
		}
		var res v2Comments
		if err := f.get(ctx, path, q, &res); err != nil {
			if cursor == "" && isNotFound(err) {
				return nil, errNotFound
			}
			return nil, fmt.Errorf("confluence: listing %s: %w", path, err)
		}
		out = append(out, res.Results...)
		next, err := nextCursor(res.Links.Next)
		if err != nil || next == "" {
			return out, err
		}
		cursor = next
	}
}

// commentItem maps one comment; parent is the comment it replies to (nil
// for a top-level comment).
func commentItem(loc, pageID string, c *v2Comment, parent *extsync.Item) (extsync.Item, error) {
	modified, err := parseTime(c.Version.CreatedAt)
	if err != nil {
		return extsync.Item{}, err
	}
	sections, users, _ := StorageToSections(c.Body.Storage.Value, maxBodyRunes)
	parts := make([]string, 0, 2*len(sections))
	for _, s := range sections {
		parts = append(parts, s.Heading, s.Text)
	}
	it := extsync.Item{
		Ref: extsync.ItemRef{Kind: extsync.KindComment, ExtID: c.ID, Version: c.Version.Number, Modified: modified, ParentID: pageID},
		// v2 comments carry no creator: the version author and time are the
		// closest (the creator's, for an unedited comment).
		AuthorID:         c.Version.AuthorID,
		Created:          modified,
		Status:           c.Status,
		Sections:         []extsync.Section{{Text: joinNonEmpty(parts, "\n\n")}},
		CommentKind:      loc,
		AnchorText:       c.Properties.InlineOriginalSelection,
		Resolved:         c.ResolutionStatus == "resolved",
		MentionedUserIDs: users,
	}
	if parent != nil {
		if it.AnchorText == "" {
			it.AnchorText = parent.AnchorText
		}
		if c.ResolutionStatus == "" {
			it.Resolved = parent.Resolved
		}
	}
	return it, nil
}

func joinNonEmpty(parts []string, sep string) string {
	kept := parts[:0:0]
	for _, p := range parts {
		if p != "" {
			kept = append(kept, p)
		}
	}
	return strings.Join(kept, sep)
}
