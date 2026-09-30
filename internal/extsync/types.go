// Package extsync is the source-agnostic sync engine for external knowledge
// sources (spec docs/superpowers/specs/2026-09-26-confluence-knowledge-connector-design.md
// §3, §6). It drives a Fetcher, owns the per-source cursors, pagination
// tokens, cycle budget and version gate, and writes the ext_* tables. It
// knows nothing about Confluence: a provider supplies a Fetcher.
package extsync

import (
	"context"
	"io"
	"log"
	"time"
)

// Section is one text section of a document (heading-split body, one per
// comment, or extracted attachment text). Stored as JSON in
// ext_documents.sections_json.
type Section struct {
	Heading string `json:"heading,omitempty"`
	Anchor  string `json:"anchor,omitempty"`
	Text    string `json:"text"`
}

// Container is one synced external container (a Confluence space).
type Container struct{ Key, Name, ExtID string }

// ItemKind names the kind of an external item.
type ItemKind string

// Item kinds. The pages stream enumerates KindPage and KindBlogpost together.
const (
	KindPage       ItemKind = "page"
	KindBlogpost   ItemKind = "blogpost"
	KindComment    ItemKind = "comment"
	KindAttachment ItemKind = "attachment"
)

// ItemRef is one enumeration row: identity, version and modification time,
// no body.
type ItemRef struct {
	Kind     ItemKind
	ExtID    string
	Version  int
	Modified time.Time
	ParentID string // comment → page, attachment → page/blogpost
}

// Item is fetched content.
type Item struct {
	Ref              ItemRef
	Title            string
	URL              string
	AuthorID         string
	Created          time.Time
	Status           string // "current" | "archived"
	Sections         []Section
	Meta             map[string]string
	CommentKind      string // "footer" | "inline" (comments only)
	AnchorText       string
	Resolved         bool
	ReplyTo          string // comments: the ext id of the comment this one replies to ("" = top-level)
	Download         string // attachments: API path for Download
	MediaType        string
	Size             int64
	MentionedUserIDs []string // author ids referenced in the body (for the users cache)
}

// User is one resolved external user.
type User struct{ ID, DisplayName, Email string }

// Fetcher is the provider side of the engine: "what changed of kind K since
// T", "give me the content", "give me every id".
type Fetcher interface {
	Containers(ctx context.Context) ([]Container, error)
	// Changed lists refs of one kind modified at or after since, ascending by
	// Modified; page is an opaque pagination token ("" = first page), next ""
	// means the enumeration is complete.
	Changed(ctx context.Context, c Container, kind ItemKind, since time.Time, page string) (refs []ItemRef, next string, err error)
	All(ctx context.Context, c Container, kind ItemKind, page string) (refs []ItemRef, next string, err error)
	Fetch(ctx context.Context, c Container, ref ItemRef) (*Item, error) // nil,nil = gone
	Comments(ctx context.Context, c Container, pageID string) ([]Item, error)
	// Download opens an attachment's bytes, at most limit of them. A body
	// above limit fails with ErrTooLarge (upfront, or from a Read of the
	// returned body); an attachment deleted since Fetch fails with ErrGone.
	// Both must match with errors.Is.
	Download(ctx context.Context, it *Item, limit int64) (io.ReadCloser, error)
	Users(ctx context.Context, ids []string) (map[string]User, error)
}

// Extractor turns attachment bytes into sections (internal/extract supplies
// the implementation).
type Extractor interface {
	Extract(ctx context.Context, mediaType, name string, r io.Reader) (sections []Section, status string, err error)
}

// OCRCapable is optionally implemented by an Extractor: HasOCR reports
// whether OCR is available, so a retry of OCR-pending attachments can be
// skipped when it is not.
type OCRCapable interface {
	HasOCR(ctx context.Context) bool
}

// TempSweeper is optionally implemented by an Extractor: SweepStale removes
// the temp files a process killed mid-extraction left behind (EXT-03), and
// reports how many. The engine calls it at the start of every run.
type TempSweeper interface {
	SweepStale(now time.Time) (int, error)
}

// TypeSupporter is optionally implemented by an Extractor: Supports reports
// whether Extract handles a media type / file name, i.e. would never answer
// skipped_type for it. With it, the engine re-extracts once the attachments
// stored as skipped_type while no Extractor was wired (see
// reextractSkipped).
type TypeSupporter interface {
	Supports(mediaType, name string) bool
}

// Options configures an Engine.
type Options struct {
	Budget    time.Duration    // 0 = unbounded
	Now       func() time.Time // default time.Now; the engine reads the clock only through it
	Logger    *log.Logger      // default: discard
	Extractor Extractor        // nil → attachments stored as skipped_type
	// ScopesOK reports whether an account's grant carries the scopes the
	// sources need; false records needs_consent without any network call.
	// An error (the stored grant is unreadable) is logged and records every
	// source of the account as error with its text — never needs_consent,
	// which would send the owner to re-consent over a corrupt file.
	// nil = assume granted.
	ScopesOK func(jiraAccountID int64) (bool, error)
	// Hints returns the re-consent hint texts recorded on a source whose
	// account's grant is revoked / lacks the scopes (ext_sources.error, and
	// the error RunSource returns). nil = a generic provider-neutral text;
	// the provider's wording (which command to run) belongs to the wiring,
	// not the engine.
	Hints func(jiraAccountID int64) (revoked, consent string)
	// Relink records the cross-source links of every document the engine
	// writes or deletes, inside the batch transaction (see RelinkFunc).
	// nil = no links.
	Relink RelinkFunc
}

// Stats summarizes one Run or RunSource.
type Stats struct {
	Fetched, Unchanged, Deleted, Comments int
	Incomplete                            bool // the budget ran out before every source caught up
}

func (s *Stats) add(o Stats) {
	s.Fetched += o.Fetched
	s.Unchanged += o.Unchanged
	s.Deleted += o.Deleted
	s.Comments += o.Comments
	s.Incomplete = s.Incomplete || o.Incomplete
}
