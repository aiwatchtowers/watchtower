package inboxfeed

import (
	"encoding/json"
	"os"
	"strconv"
	"testing"

	"watchtower/internal/tower/api"
)

const approvalTextPath = "testdata/approval_text_cases.json"

// approvalTextCase is one case of the shared approval text fixture: a
// proposal's tool, args and result, and the card text the Mac draws for it
// (AgentActionCardView, SaveAutomationProposalPane). The app target's
// ApprovalTextParityTests runs the Swift card code over the same cases.
type approvalTextCase struct {
	Name   string `json:"name"`
	Tool   string `json:"tool"`
	Args   string `json:"args"`
	Result string `json:"result"`
	// Status is the row's status ("" reads as pending).
	Status         string            `json:"status,omitempty"`
	WorkbenchNames map[string]string `json:"workbench_names"`
	Expect         struct {
		Title      string         `json:"title"`
		Summary    []string       `json:"summary"`
		EditOnMac  bool           `json:"edit_on_mac"`
		Disclosure string         `json:"disclosure"`
		RecipeText string         `json:"recipe_text"`
		Diff       []api.DiffLine `json:"diff"`
	} `json:"expect"`
}

// TestApprovalText_SharedCases: ApprovalTextOf equals every case's expect;
// -update rewrites the expects.
func TestApprovalText_SharedCases(t *testing.T) {
	b, err := os.ReadFile(approvalTextPath)
	if err != nil {
		t.Fatal(err)
	}
	var cases []approvalTextCase
	if err := json.Unmarshal(b, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) < 20 {
		t.Fatalf("the fixture has %d cases", len(cases))
	}
	for i, c := range cases {
		status := c.Status
		if status == "" {
			status = "pending"
		}
		got := ApprovalTextOf(c.Tool, c.Args, c.Result, status, func(id int64) string {
			return c.WorkbenchNames[strconv.FormatInt(id, 10)]
		})
		if *update {
			e := &cases[i].Expect
			e.Title, e.Summary, e.EditOnMac = got.Title, got.Summary, got.EditOnMac
			e.Disclosure, e.RecipeText, e.Diff = got.Disclosure, got.RecipeText, got.Diff
			if e.Diff == nil {
				e.Diff = []api.DiffLine{}
			}
			continue
		}
		if got.Diff == nil {
			got.Diff = []api.DiffLine{}
		}
		g, _ := json.Marshal(got)
		w, _ := json.Marshal(ApprovalText{Title: c.Expect.Title, Summary: c.Expect.Summary, EditOnMac: c.Expect.EditOnMac,
			Disclosure: c.Expect.Disclosure, RecipeText: c.Expect.RecipeText, Diff: c.Expect.Diff})
		if string(g) != string(w) {
			t.Errorf("%s:\n got %s\nwant %s", c.Name, g, w)
		}
	}
	if *update {
		out, err := json.MarshalIndent(cases, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(approvalTextPath, append(out, '\n'), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

// TestRawIndented: the connector input is re-indented as written — key
// order and number spelling kept, a printable \u escape decoded.
func TestRawIndented(t *testing.T) {
	raw, ok := rawMember("input", `{"server":"a","input":{"b":1.50,"a":[],"c":{"d":"\u00e9\n"}},"tool":"x"}`)
	if !ok {
		t.Fatal("no input member")
	}
	want := "{\n  \"b\": 1.50,\n  \"a\": [],\n  \"c\": {\n    \"d\": \"é\\n\"\n  }\n}"
	if got := rawIndented(raw); got != want {
		t.Errorf("got %q\nwant %q", got, want)
	}
}
