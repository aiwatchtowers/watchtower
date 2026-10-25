package ideas

import (
	"encoding/json"
	"os"
	"testing"
)

func TestParseKnowledgePrefix_Fixture(t *testing.T) {
	raw, err := os.ReadFile("testdata/knowledge_prefix_cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Text string `json:"text"`
		Ok   bool   `json:"ok"`
		Kind string `json:"kind"`
		Body string `json:"body"`
	}
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) < 10 {
		t.Fatalf("fixture has %d cases", len(cases))
	}
	for _, c := range cases {
		kind, body, ok := ParseKnowledgePrefix(c.Text)
		if ok != c.Ok || kind != c.Kind || body != c.Body {
			t.Errorf("ParseKnowledgePrefix(%q) = (%q, %q, %v), want (%q, %q, %v)",
				c.Text, kind, body, ok, c.Kind, c.Body, c.Ok)
		}
	}
}
