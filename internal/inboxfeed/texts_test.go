package inboxfeed

import (
	"encoding/json"
	"os"
	"strconv"
	"testing"

	"watchtower/internal/tower/api"
)

// TestSaveAutomationSummary_SharedCases runs the shared fixture that
// InboxFeedParityTests.testSaveAutomationSummaryMatchesGo runs through the
// Swift SaveAutomationProposalSummary.
func TestSaveAutomationSummary_SharedCases(t *testing.T) {
	b, err := os.ReadFile("testdata/save_automation_summary_cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Name           string                `json:"name"`
		Args           string                `json:"args"`
		WorkbenchNames map[string]string     `json:"workbench_names"`
		Expect         SaveAutomationSummary `json:"expect"`
	}
	if err := json.Unmarshal(b, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range cases {
		got := SummarizeSaveAutomation(c.Args, func(id int64) string {
			return c.WorkbenchNames[strconv.FormatInt(id, 10)]
		})
		if got != c.Expect {
			t.Errorf("%s: got %+v, want %+v", c.Name, got, c.Expect)
		}
	}
}

func TestPreview_PlainTextOfTheMarkdown(t *testing.T) {
	for in, want := range map[string]string{
		"":                                       "",
		"plain   text\nover  lines":              "plain text over lines",
		"## Head\n\n*a* **b** ~~c~~ `d`":         "Head a b c d",
		"| x | y |\n|---|---|\n| 1 | 2 |":        "x y 1 2",
		"- [x] done\n- [ ] open":                 "done open",
		"line one  \nline two":                   "line one line two",
		"see https://example.com/a now":          "see https://example.com/a now",
		"![alt text](https://example.com/i.png)": "alt text",
	} {
		if got := Preview(in); got != want {
			t.Errorf("Preview(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestRefsOf_UnreadableDocumentsHaveNone(t *testing.T) {
	ok := `{"v":1,"blocks":[{"type":"text","text":"x"},{"type":"list","rows":[` +
		`{"title":"a","ref":{"kind":"track","id":3}},{"title":"b"},{"title":"c","ref":null}]}]}`
	if got := refsOf(ok); len(got) != 1 || got[0] != (ref{api.RefTrack, 3}) {
		t.Fatalf("refsOf(readable) = %+v", got)
	}
	for _, bad := range []string{
		``, `not json`, `{"v":2,"blocks":[]}`, `{"v":true,"blocks":[]}`, `{"v":1}`,
		`{"v":1,"blocks":[{"type":"poem"}]}`,
		`{"v":1,"blocks":[{"type":"list"}]}`,
		`{"v":1,"blocks":[{"type":"list","rows":[{"title":""}]}]}`,
		`{"v":1,"blocks":[{"type":"list","rows":[{"title":"a","ref":{"kind":"plan_item","id":1}}]}]}`,
		`{"v":1,"blocks":[{"type":"list","rows":[{"title":"a","ref":{"kind":"track","id":0}}]}]}`,
		`{"v":1,"blocks":[{"type":"list","rows":[{"title":"a","ref":{"kind":"track","id":1.5}}]}]}`,
		`{"v":1,"blocks":[{"type":"list","rows":[{"title":"a","ref":{"kind":"track","id":"1"}}]}]}`,
	} {
		if got := refsOf(bad); len(got) != 0 {
			t.Errorf("refsOf(%q) = %+v, want none", bad, got)
		}
	}
}
