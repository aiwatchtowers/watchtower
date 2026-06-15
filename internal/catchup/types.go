// Package catchup builds an on-demand AI rollup of currently-unread items
// across digests, tracks, inbox, and briefings, clustered into thematic stories.
package catchup

// Ref links a story back to a source item.
type Ref struct {
	Area  string `json:"area"` // digests|tracks|inbox|briefings
	ID    int    `json:"id"`
	Label string `json:"label"`
}

// Story is a cross-source thematic cluster of unread items.
type Story struct {
	Title     string `json:"title"`
	Narrative string `json:"narrative"`
	Priority  string `json:"priority"` // high|medium|low
	NeedsYou  bool   `json:"needs_you"`
	Refs      []Ref  `json:"refs"`
}

// SectionItem is one clearable unread row.
type SectionItem struct {
	ID      int    `json:"id"`
	Title   string `json:"title"`
	Snippet string `json:"snippet"`
}

// Section is the raw per-area unread set; its item IDs drive clearing.
type Section struct {
	Area     string        `json:"area"`
	Total    int           `json:"total"`
	Included int           `json:"included"`
	Items    []SectionItem `json:"items"`
}

// AreaCount reports included vs uncapped totals per area.
type AreaCount struct {
	Included int `json:"included"`
	Total    int `json:"total"`
}

// Counts aggregates per-area and overall unread totals.
type Counts struct {
	Digests       AreaCount `json:"digests"`
	Tracks        AreaCount `json:"tracks"`
	Inbox         AreaCount `json:"inbox"`
	Briefings     AreaCount `json:"briefings"`
	TotalUnread   int       `json:"total_unread"`
	TotalIncluded int       `json:"total_included"`
}

// Result is the full catch-up rollup emitted as JSON by the CLI.
type Result struct {
	TLDR      string    `json:"tldr"`
	Counts    Counts    `json:"counts"`
	Truncated bool      `json:"truncated"`
	Stories   []Story   `json:"stories"`
	Sections  []Section `json:"sections"`
}

// aiOutput is the narrow shape the model returns; sections come from the DB,
// not the model, so the model only produces the reading layer.
type aiOutput struct {
	TLDR    string  `json:"tldr"`
	Stories []Story `json:"stories"`
}
