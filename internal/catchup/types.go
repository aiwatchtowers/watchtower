// Package catchup builds an on-demand, persisted review session over the
// currently-unread items across digests, tracks, inbox, and briefings. A cheap
// outline pass clusters them into thematic skeletons; a per-theme expand pass
// fills in the narrative. Themes/sessions persist in SQLite and stream to the
// SwiftUI app via GRDB observation.
package catchup

import (
	"encoding/json"
	"fmt"
	"strings"

	"watchtower/internal/db"
)

// outlineResult is the shape the outline AI call returns: a clustered set of
// theme skeletons referencing only the ids that were supplied as input.
type outlineResult struct {
	Themes []outlineTheme `json:"themes"`
}

// outlineTheme is one skeleton theme from the outline pass.
type outlineTheme struct {
	Title    string          `json:"title"`
	Priority string          `json:"priority"`
	Refs     []db.CatchupRef `json:"refs"`
}

// expandResult is the shape the per-theme expand AI call returns: the rich
// narrative plus the review hints for a single theme.
type expandResult struct {
	Narrative       string `json:"narrative"`
	Priority        string `json:"priority"`
	NeedsYou        bool   `json:"needs_you"`
	SuggestedAction string `json:"suggested_action"`
}

// parseExpand extracts the expand object, tolerating markdown fences.
func parseExpand(raw string) (expandResult, error) {
	var out expandResult
	s := trimToJSONObject(raw)
	if err := json.Unmarshal([]byte(s), &out); err != nil {
		return expandResult{}, fmt.Errorf("parsing catchup expand output: %w", err)
	}
	return out, nil
}

// parseOutline extracts the {themes:[...]} object, tolerating markdown fences.
func parseOutline(raw string) (outlineResult, error) {
	var out outlineResult
	s := trimToJSONObject(raw)
	if err := json.Unmarshal([]byte(s), &out); err != nil {
		return outlineResult{}, fmt.Errorf("parsing catchup outline output: %w", err)
	}
	return out, nil
}

// parseRefs decodes a theme's refs JSON column into typed refs.
func parseRefs(raw string) ([]db.CatchupRef, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}
	var refs []db.CatchupRef
	if err := json.Unmarshal([]byte(raw), &refs); err != nil {
		return nil, fmt.Errorf("parsing catchup refs: %w", err)
	}
	return refs, nil
}

// trimToJSONObject narrows a model response to the outermost {...} so leading
// prose or markdown fences do not break json.Unmarshal.
func trimToJSONObject(raw string) string {
	s := raw
	if i := strings.Index(s, "{"); i >= 0 {
		if j := strings.LastIndex(s, "}"); j >= i {
			s = s[i : j+1]
		}
	}
	return s
}
