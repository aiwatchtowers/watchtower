package automations

import (
	"cmp"
	"context"
	"fmt"
	"slices"

	"watchtower/internal/db"
)

const confluencePageChanged = "confluence.page_changed"

// ConfluenceSource is phaseExternalSync's event source: one
// confluence.page_changed per page the phase stored new or at a higher
// version, in a space whose backfill was done before the phase — a space's
// backfill (and a space selected during the phase) publishes nothing. In v1
// a comment-only change (children_changed_at), blog posts and attachments
// are not events.
func ConfluenceSource(d *db.DB) EventSource { return confluenceSource{d: d} }

type confluenceSource struct{ d *db.DB }

func (confluenceSource) Type() string { return confluencePageChanged }

func (s confluenceSource) Before(context.Context) (EventDiff, error) {
	sources, err := s.d.ConfluenceSourceMarks()
	if err != nil {
		return nil, fmt.Errorf("snapshotting confluence sources: %w", err)
	}
	versions, err := s.d.ConfluencePageVersions()
	if err != nil {
		return nil, fmt.Errorf("snapshotting confluence pages: %w", err)
	}
	return confluenceDiff{d: s.d, sources: sources, before: versions}, nil
}

type confluenceDiff struct {
	d       *db.DB
	sources map[int64]db.ConfluenceSourceMark
	before  map[db.ConfluencePageRef]int64
}

func (s confluenceDiff) After(ctx context.Context) ([]Event, error) {
	after, err := s.d.ConfluencePageVersions()
	if err != nil {
		return nil, fmt.Errorf("reading confluence pages: %w", err)
	}
	var events []Event
	for _, ref := range sortedPageRefs(after) {
		if err := ctx.Err(); err != nil {
			return nil, fmt.Errorf("diffing confluence pages: %w", err)
		}
		src, ok := s.sources[ref.SourceID]
		if !ok || !src.BackfillDone {
			continue
		}
		if v, seen := s.before[ref]; seen && after[ref] <= v {
			continue
		}
		events = append(events, Event{Type: confluencePageChanged, Fields: map[string]any{
			"space": src.Space, "page_id": ref.PageID,
		}})
	}
	return events, nil
}

// sortedPageRefs returns versions' pages ordered by source, then page id.
func sortedPageRefs(versions map[db.ConfluencePageRef]int64) []db.ConfluencePageRef {
	refs := make([]db.ConfluencePageRef, 0, len(versions))
	for ref := range versions {
		refs = append(refs, ref)
	}
	slices.SortFunc(refs, func(x, y db.ConfluencePageRef) int {
		return cmp.Or(cmp.Compare(x.SourceID, y.SourceID), cmp.Compare(x.PageID, y.PageID))
	})
	return refs
}
