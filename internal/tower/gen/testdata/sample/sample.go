// Package sample holds the generator's sample types: one of each mapping
// rule, generated into ../sample.swift.golden.
package sample

import "encoding/json"

// Mood is a string enum; "unknown" collides with the catch-all case.
type Mood string

// EnumValues lists every Mood.
func (Mood) EnumValues() []string { return []string{"calm", "not_sure", "unknown"} }

// Base is embedded: its fields are flattened into the embedding struct.
type Base struct {
	RequestID string `json:"request_id"`
}

// Inner is a nested struct.
type Inner struct {
	Name string `json:"name"`
}

// Sample uses every mapping rule.
type Sample struct {
	Base
	ID      string          `json:"id"`
	Count   int             `json:"count"`
	Big     int64           `json:"big"`
	Ratio   float64         `json:"ratio"`
	Done    bool            `json:"done"`
	Parent  *Inner          `json:"parent"`
	Note    string          `json:"note,omitempty"`
	Tags    []string        `json:"tags"`
	Scores  map[string]int  `json:"scores"`
	Inner   Inner           `json:"inner"`
	Mood    Mood            `json:"mood"`
	Extra   json.RawMessage `json:"extra,omitempty"`
	Skipped string          `json:"-"`
}
