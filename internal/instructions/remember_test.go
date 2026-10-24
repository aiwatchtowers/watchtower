package instructions

import (
	"encoding/json"
	"os"
	"testing"
)

func TestParseRemember_Fixture(t *testing.T) {
	raw, err := os.ReadFile("testdata/remember_cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Text string `json:"text"`
		Ok   bool   `json:"ok"`
		Line string `json:"line"`
	}
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) < 8 {
		t.Fatalf("fixture has %d cases", len(cases))
	}
	for _, c := range cases {
		line, ok := ParseRemember(c.Text)
		if ok != c.Ok || line != c.Line {
			t.Errorf("ParseRemember(%q) = (%q, %v), want (%q, %v)", c.Text, line, ok, c.Line, c.Ok)
		}
	}
}
