package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/userguide"
)

const (
	guideDefaultLimit = 5
	guideMaxLimit     = 10
)

type searchGuideArgs struct {
	Query string `json:"query" jsonschema:"what the owner asks about the app, in a few key words (English)"`
	Limit int    `json:"limit,omitempty" jsonschema:"max sections, 0 = default (5), capped at 10"`
}

type getGuidePageArgs struct {
	Page string `json:"page" jsonschema:"guide page id from search_guide"`
}

type guideSection struct {
	Page    string `json:"page"`
	Heading string `json:"heading"`
	Anchor  string `json:"anchor"`
	URL     string `json:"url"`
	Text    string `json:"text"`
}

// NewSearchGuide searches the embedded user guide. version selects the
// published guide URL the sections link to.
func NewSearchGuide(version string) *Tool {
	return &Tool{
		Name: "search_guide",
		Description: "Search the Watchtower user guide — how each tab, setting and feature works and why " +
			"something may be empty. Use it for any question about how to use the app. Returns sections " +
			"with page, heading, anchor, url and text; answer from them, and say the guide doesn't cover " +
			"it when nothing matches.",
		InputSchema: mustSchema[searchGuideArgs]("search_guide"),
		Access:      AccessRead,
		Surfaces:    []string{"main"},
		Execute: func(_ context.Context, _ *db.DB, call Call) (any, error) {
			var a searchGuideArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			if strings.TrimSpace(a.Query) == "" {
				return nil, &ValidationError{Msg: "query is required"}
			}
			limit := a.Limit
			if limit <= 0 {
				limit = guideDefaultLimit
			}
			limit = min(limit, guideMaxLimit)
			all, err := userguide.Load()
			if err != nil {
				return nil, fmt.Errorf("loading the guide: %w", err)
			}
			base := userguide.BaseURL(version)
			out := []guideSection{}
			for _, s := range userguide.Search(all, a.Query, limit) {
				out = append(out, guideSection{Page: s.Page, Heading: s.Heading, Anchor: s.Anchor,
					URL: base + s.Page + "#" + s.Anchor, Text: s.Text})
			}
			return map[string]any{"sections": out}, nil
		},
	}
}

// NewGetGuidePage returns one whole guide page.
func NewGetGuidePage(version string) *Tool {
	return &Tool{
		Name:        "get_guide_page",
		Description: "Read one whole page of the Watchtower user guide by its page id (from search_guide).",
		InputSchema: mustSchema[getGuidePageArgs]("get_guide_page"),
		Access:      AccessRead,
		Surfaces:    []string{"main"},
		Execute: func(_ context.Context, _ *db.DB, call Call) (any, error) {
			var a getGuidePageArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			all, err := userguide.Load()
			if err != nil {
				return nil, fmt.Errorf("loading the guide: %w", err)
			}
			secs, ok := userguide.Page(all, a.Page)
			if !ok || len(secs) == 0 {
				return nil, &ValidationError{Msg: "unknown guide page; use search_guide"}
			}
			var b strings.Builder
			for i, s := range secs {
				if i > 0 && s.Heading != "" {
					b.WriteString(strings.Repeat("#", s.Level) + " " + s.Heading + "\n")
				}
				b.WriteString(s.Text + "\n\n")
			}
			return map[string]any{
				"page":  a.Page,
				"title": secs[0].PageTitle,
				"url":   userguide.BaseURL(version) + a.Page,
				"text":  strings.TrimSpace(b.String()),
			}, nil
		},
	}
}
