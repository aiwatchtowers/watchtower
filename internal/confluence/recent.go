package confluence

import (
	"context"
	"fmt"
)

const (
	// recentSpacesCQL lists the pages and blog posts the signed-in user
	// created or edited in the last 90 days, or viewed in the last 90 days
	// (the 100 most recent views), newest edit first: the spaces they sit in
	// are the default selection of a new site (#573).
	recentSpacesCQL = `type IN (page, blogpost) AND ((contributor = currentUser() AND lastmodified >= now("-90d")) ` +
		`OR id IN recentlyViewedContent(100, 90)) ORDER BY lastmodified DESC`
	// recentSpacesMaxPages caps the listing at 300 results: enough to find
	// the spaces someone works in, and a bounded wait in the connect sheet.
	recentSpacesMaxPages = 3
)

// RecentSpaceKeys returns the keys of the spaces holding content the
// signed-in user wrote in or viewed lately, in order of first sighting
// (most recent first), each once. Empty when there is none. A GET-only CQL
// search, like every other listing (EXT-01).
func (f *Fetcher) RecentSpaceKeys(ctx context.Context) ([]string, error) {
	seen := map[string]bool{}
	var keys []string
	cursor := ""
	for range recentSpacesMaxPages {
		res, next, err := f.search(ctx, recentSpacesCQL, "space", cursor)
		if err != nil {
			return nil, fmt.Errorf("confluence: listing recent spaces: %w", err)
		}
		for _, r := range res.Results {
			if k := r.Space.Key; k != "" && visible(r.Status) && !seen[k] {
				seen[k] = true
				keys = append(keys, k)
			}
		}
		if next == "" {
			break
		}
		cursor = next
	}
	return keys, nil
}
