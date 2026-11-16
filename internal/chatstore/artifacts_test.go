package chatstore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

type artifactCase struct {
	Name   string `json:"name"`
	Text   string `json:"text"`
	Final  bool   `json:"final"`
	Expect []struct {
		Key     string            `json:"key"`
		Kind    string            `json:"kind"`
		Title   string            `json:"title"`
		Content string            `json:"content"`
		Meta    map[string]string `json:"meta"`
	} `json:"expect"`
}

// TestParseArtifacts_SharedCases runs the fixture the Swift
// ArtifactParseFixtureTests reads too (dual path, pinned from both sides).
func TestParseArtifacts_SharedCases(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "chat", "testdata", "artifact_parse_cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var cases []artifactCase
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) < 12 {
		t.Fatalf("fixture has %d cases, want at least 12", len(cases))
	}
	for _, tc := range cases {
		t.Run(tc.Name, func(t *testing.T) {
			var want []ParsedArtifact
			for _, e := range tc.Expect {
				want = append(want, ParsedArtifact{Key: e.Key, Kind: e.Kind, Title: e.Title, Content: e.Content, Meta: e.Meta})
			}
			got := ParseArtifacts(tc.Text, tc.Final)
			for i := range got {
				if len(got[i].Meta) == 0 {
					got[i].Meta = nil
				}
			}
			for i := range want {
				if len(want[i].Meta) == 0 {
					want[i].Meta = nil
				}
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("got %+v\nwant %+v", got, want)
			}
		})
	}
}
