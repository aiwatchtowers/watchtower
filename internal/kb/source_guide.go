package kb

import (
	"context"
	"time"

	"watchtower/docs/guide"
)

// GuideSource is the knowledge source of the embedded Watchtower user guide.
const GuideSource = "guide"

// guideSource renders one document per guide page. The pages are embedded in
// the binary, so the whole source changes together: its cursor is the guide
// content hash plus the link base (a new release version relinks every page
// to its tag; see guideCursor). Keys are document ids ("guide:<path>", path relative to
// docs/guide/), like every other source.
type guideSource struct{}

func (guideSource) Name() string { return GuideSource }

func (guideSource) Changed(_ context.Context, _ Queryer, cursor string, _ time.Time) ([]string, string, bool, error) {
	h := guideCursor()
	if cursor == h {
		return nil, h, true, nil
	}
	return guideKeys(), h, true, nil
}

// guideCursor is the guide content hash and the link base: either moving
// re-renders every page.
func guideCursor() string { return guide.Hash() + "@" + guide.BaseURL(guide.Version) }

func (guideSource) Keys(context.Context, Queryer) ([]string, error) { return guideKeys(), nil }

func guideKeys() []string {
	pages := guide.Pages()
	keys := make([]string, 0, len(pages))
	for _, p := range pages {
		keys = append(keys, GuideSource+":"+p.Path)
	}
	return keys
}

func (guideSource) Build(_ context.Context, _ Queryer, key string) (*Doc, error) {
	path, ok := splitRef(key, GuideSource+":")
	if !ok {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}
	for _, p := range guide.Pages() {
		if p.Path != path {
			continue
		}
		doc := &Doc{
			ID:     key,
			Source: GuideSource,
			Title:  p.Title,
			Link:   guide.BaseURL(guide.Version) + p.Path,
			Anchor: map[string]string{"path": p.Path},
		}
		for _, s := range p.Sections {
			doc.Sections = append(doc.Sections, Section{Text: s.Heading + "\n" + s.Text, Anchor: s.Anchor})
		}
		return doc, nil
	}
	return nil, nil
}
