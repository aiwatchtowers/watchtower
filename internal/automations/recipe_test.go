package automations

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func readFixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", "recipes", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return data
}

// recipeWith builds a recipe file from a frontmatter body and a script.
func recipeWith(frontmatter, script string) []byte {
	return []byte("---\n" + frontmatter + "---\nDescription.\n\n```js\n" + script + "```\n")
}

const baseFrontmatter = "name: Test\ntrigger:\n  manual: true\n"

func mustParse(t *testing.T, data []byte, scope Scope) *Recipe {
	t.Helper()
	r, err := ParseRecipe("ok", data, scope)
	if err != nil {
		t.Fatalf("ParseRecipe: %v", err)
	}
	return r
}

// wantParseError asserts a *ParseError containing contains and returns its line
// and full message.
func wantParseError(t *testing.T, data []byte, contains string) (line int, msg string) {
	t.Helper()
	_, err := ParseRecipe("ok", data, Scope{Kind: ScopePersonal})
	if err == nil {
		t.Fatalf("ParseRecipe: want error containing %q, got nil", contains)
	}
	var pe *ParseError
	if !errors.As(err, &pe) {
		t.Fatalf("ParseRecipe: want *ParseError, got %T: %v", err, err)
	}
	if !strings.Contains(err.Error(), contains) {
		t.Fatalf("ParseRecipe error %q does not contain %q", err.Error(), contains)
	}
	return pe.Line, pe.Error()
}

func TestRecipe_ParsesFrontmatterDescriptionAndOneJSBlock(t *testing.T) {
	r := mustParse(t, readFixture(t, "ok.md"), Scope{Kind: ScopePersonal})

	// Every field but the description, compared whole: slug, name, a schedule
	// trigger with no button/event, permissions, outputs, the defaults
	// (tokens 50000, minutes 5, concurrency 1, missed run_once, pause 72),
	// ScriptLine = the line after the fence, the exact script and the scope.
	want := Recipe{
		Slug:              "ok",
		Name:              "New mail summary",
		Trigger:           Trigger{Kind: TriggerSchedule, Schedule: "0 9 * * 1-5"},
		Missed:            MissedRunOnce,
		Concurrency:       1,
		Permissions:       []string{"gmail:read@work", "llm:light"},
		Outputs:           []string{"inbox"},
		Budget:            Budget{Tokens: 50000, Minutes: 5},
		PauseTimeoutHours: 72,
		Script: "const mail = tool(\"list_emails\", { account: \"work\" });\n" +
			"output.inbox({ title: \"Mail\", body: llm(\"Summarise\", mail) });\n",
		ScriptLine: 13,
		Scope:      Scope{Kind: ScopePersonal},
	}
	got := *r
	got.Description = ""
	if !reflect.DeepEqual(got, want) {
		t.Errorf("recipe:\n got: %+v\nwant: %+v", got, want)
	}
	assertDescription(t, r.Description,
		[]string{"Summarises new mail", "Shown on the card"}, // text on both sides of the block
		[]string{"```", "tool("})                             // the block itself is not description
}

// assertDescription checks that desc contains every want and none of reject.
func assertDescription(t *testing.T, desc string, want, reject []string) {
	t.Helper()
	for _, s := range want {
		if !strings.Contains(desc, s) {
			t.Errorf("description %q lacks %q", desc, s)
		}
	}
	for _, s := range reject {
		if strings.Contains(desc, s) {
			t.Errorf("description %q contains %q", desc, s)
		}
	}
}

func TestRecipe_AcceptsJavascriptInfoString(t *testing.T) {
	data := []byte("---\n" + baseFrontmatter + "---\n```javascript\nlog(1);\n```\n")
	r := mustParse(t, data, Scope{Kind: ScopePersonal})
	if r.Script != "log(1);\n" {
		t.Errorf("script = %q", r.Script)
	}
	if r.ScriptLine != 7 {
		t.Errorf("ScriptLine = %d, want 7", r.ScriptLine)
	}
	if r.Description != "" {
		t.Errorf("description = %q, want empty", r.Description)
	}
}

func TestRecipe_RejectsZeroOrTwoJSBlocks(t *testing.T) {
	zero := []byte("---\n" + baseFrontmatter + "---\nNo script here.\n\n```bash\necho hi\n```\n")
	wantParseError(t, zero, "js")

	two := []byte("---\n" + baseFrontmatter + "---\n```js\nlog(1);\n```\n\n```javascript\nlog(2);\n```\n")
	line, _ := wantParseError(t, two, "js")
	if line != 10 {
		t.Errorf("second block line = %d, want 10", line)
	}

	unclosed := []byte("---\n" + baseFrontmatter + "---\n```js\nlog(1);\n")
	wantParseError(t, unclosed, "not closed")

	// A js fence inside a longer non-js fence is description, not a script.
	nested := []byte("---\n" + baseFrontmatter + "---\n````md\n```js\nx\n```\n````\n```js\nlog(1);\n```\n")
	r := mustParse(t, nested, Scope{Kind: ScopePersonal})
	if r.Script != "log(1);\n" {
		t.Errorf("nested: script = %q", r.Script)
	}
}

func TestRecipe_RejectsUnknownKeyAndBadSlug(t *testing.T) {
	line, _ := wantParseError(t, recipeWith(baseFrontmatter+"permision:\n  - llm:light\n", "log(1);\n"), "permision")
	if line != 5 {
		t.Errorf("unknown key line = %d, want 5", line)
	}
	wantParseError(t, recipeWith(baseFrontmatter+"budget: {tokens: 1000, minuts: 2}\n", "x\n"), "minuts")
	wantParseError(t, recipeWith("name: T\ntrigger:\n  button: {label: Go, colour: red}\n", "x\n"), "colour")

	for _, s := range []string{"Bad_Slug", "-x", strings.Repeat("a", 65), "", "a.b", "ok "} {
		if ValidSlug(s) {
			t.Errorf("ValidSlug(%q) = true", s)
		}
	}
	for _, s := range []string{"a", "0", "new-mail", strings.Repeat("a", 64), "a-"} {
		if !ValidSlug(s) {
			t.Errorf("ValidSlug(%q) = false", s)
		}
	}
	if _, err := ParseRecipe("Bad_Slug", readFixture(t, "ok.md"), Scope{Kind: ScopePersonal}); err == nil {
		t.Error("ParseRecipe with a bad slug: want error")
	}
}

func TestRecipe_RejectsWorkbenchKey(t *testing.T) {
	wantParseError(t, recipeWith(baseFrontmatter+"workbench: 3\n", "x\n"), "workbench")
}

func TestRecipe_RejectsUSDBudget(t *testing.T) {
	wantParseError(t, recipeWith(baseFrontmatter+"budget: {usd: 1}\n", "x\n"), "usd")
	wantParseError(t, recipeWith(baseFrontmatter+"budget: {tokens: 5000, usd: 1}\n", "x\n"), "usd")
}

// badCase is a recipe the parser must refuse with a *ParseError whose message
// names contains and whose line is line.
type badCase struct {
	label, frontmatter, contains string
	line                         int
}

func assertBadCases(t *testing.T, cases []badCase) {
	t.Helper()
	for _, c := range cases {
		_, err := ParseRecipe("ok", recipeWith(c.frontmatter, "x\n"), Scope{Kind: ScopePersonal})
		var pe *ParseError
		if !errors.As(err, &pe) {
			t.Errorf("%s: want *ParseError, got %T: %v", c.label, err, err)
			continue
		}
		if !strings.Contains(pe.Msg, c.contains) || pe.Line != c.line {
			t.Errorf("%s: got %q (line %d), want it to name %q on line %d", c.label, pe.Msg, pe.Line, c.contains, c.line)
		}
	}
}

func TestRecipe_BudgetBounds(t *testing.T) {
	b := baseFrontmatter // keys added after it start on line 5
	assertBadCases(t, []badCase{
		{"tokens low", b + "budget: {tokens: 999}\n", "budget.tokens", 5},
		{"tokens high", b + "budget: {tokens: 2000001}\n", "budget.tokens", 5},
		{"minutes low", b + "budget: {minutes: 0}\n", "budget.minutes", 5},
		{"minutes high", b + "budget: {minutes: 61}\n", "budget.minutes", 5},
		{"concurrency low", b + "concurrency: 0\n", "concurrency", 5},
		{"concurrency high", b + "concurrency: 5\n", "concurrency", 5},
		{"pause low", b + "pause_timeout_hours: 0\n", "pause_timeout_hours", 5},
		{"pause high", b + "pause_timeout_hours: 169\n", "pause_timeout_hours", 5},
		{"tokens word", b + "budget: {tokens: lots}\n", "budget.tokens must be an integer", 5},
		{"tokens float", b + "budget: {tokens: 1000.7}\n", "budget.tokens must be an integer", 5},
		{"tokens quoted", b + "budget: {tokens: \"2000\"}\n", "budget.tokens must be an integer", 5},
		{"concurrency float", b + "concurrency: 1.9\n", "concurrency must be an integer", 5},
		{"minutes on its own line", b + "budget:\n  minutes: 2.0\n", "budget.minutes must be an integer", 6},
		{"budget list", b + "budget: [1, 2]\n", "budget must be a map", 5},
		{"missed", b + "missed: sometimes\n", "missed", 5},
	})

	r := mustParse(t, recipeWith(baseFrontmatter+"budget: {tokens: 1000, minutes: 1}\nconcurrency: 1\npause_timeout_hours: 1\nmissed: skip\n", "x\n"), Scope{Kind: ScopePersonal})
	if r.Budget != (Budget{Tokens: 1000, Minutes: 1}) || r.Concurrency != 1 || r.PauseTimeoutHours != 1 || r.Missed != MissedSkip {
		t.Errorf("low bounds parsed as %+v", r)
	}
	r = mustParse(t, recipeWith(baseFrontmatter+"budget: {tokens: 2000000, minutes: 60}\nconcurrency: 4\npause_timeout_hours: 168\n", "x\n"), Scope{Kind: ScopePersonal})
	if r.Budget != (Budget{Tokens: 2000000, Minutes: 60}) || r.Concurrency != 4 || r.PauseTimeoutHours != 168 {
		t.Errorf("high bounds parsed as %+v", r)
	}
	// A partial budget keeps the default for the missing half.
	r = mustParse(t, recipeWith(baseFrontmatter+"budget: {minutes: 10}\n", "x\n"), Scope{Kind: ScopePersonal})
	if r.Budget != (Budget{Tokens: DefaultBudgetTokens, Minutes: 10}) {
		t.Errorf("partial budget = %+v", r.Budget)
	}
	// An empty budget map keeps both defaults.
	r = mustParse(t, recipeWith(baseFrontmatter+"budget: {}\n", "x\n"), Scope{Kind: ScopePersonal})
	if r.Budget != (Budget{Tokens: DefaultBudgetTokens, Minutes: DefaultBudgetMinutes}) {
		t.Errorf("empty budget = %+v", r.Budget)
	}
}

// acceptedTrigger is a recipe that must parse to name and trigger.
type acceptedTrigger struct {
	label, frontmatter, name string
	trigger                  Trigger
}

func TestRecipe_TriggerExactlyOne(t *testing.T) {
	// name is line 2, trigger line 3, its first entry line 4.
	assertBadCases(t, []badCase{
		{"none", "name: T\n", "trigger", 2},
		{"empty map", "name: T\ntrigger: {}\n", "exactly one", 3},
		{"two kinds", "name: T\ntrigger:\n  manual: true\n  schedule: \"0 9 * * *\"\n", "exactly one", 4},
		{"not a map", "name: T\ntrigger: manual\n", "trigger must be a map", 3},
		{"bad cron", "name: T\ntrigger:\n  schedule: \"61 * * * *\"\n", "trigger.schedule", 4},
		{"six fields", "name: T\ntrigger:\n  schedule: \"0 0 9 * * *\"\n", "5-field", 4},
		{"descriptor", "name: T\ntrigger:\n  schedule: \"@daily\"\n", "5-field", 4},
		{"cron tz prefix", "name: T\ntrigger:\n  schedule: \"CRON_TZ=UTC 0 9 * * *\"\n", "5-field", 4},
		{"tz prefix", "name: T\ntrigger:\n  schedule: \"TZ=UTC 0 9 * *\"\n", "trigger.schedule", 4},
		{"bad event", "name: T\ntrigger:\n  event: {type: foo.bar}\n", "trigger.event.type", 4},
		{"no event type", "name: T\ntrigger:\n  event: {where: {channel: x}}\n", "trigger.event.type", 4},
		{"empty label", "name: T\ntrigger:\n  button: {label: \"\"}\n", "trigger.button.label", 4},
		{"blank label", "name: T\ntrigger:\n  button: {label: \"   \"}\n", "trigger.button.label", 4},
		{"long label", "name: T\ntrigger:\n  button: {label: \"" + strings.Repeat("x", 25) + "\"}\n", "trigger.button.label", 4},
		{"manual false", "name: T\ntrigger:\n  manual: false\n", "trigger.manual", 4},
		{"no name", "trigger:\n  manual: true\n", "name", 2},
		{"long name", "name: " + strings.Repeat("n", 81) + "\ntrigger:\n  manual: true\n", "name", 2},
		{"long multibyte name", "name: " + strings.Repeat("я", 81) + "\ntrigger:\n  manual: true\n", "name", 2},
		{"blank name", "name: \"   \"\ntrigger:\n  manual: true\n", "name", 2},
	})

	// Accepted triggers, each compared whole: a 24-char button with confirm,
	// a trimmed label with confirm defaulting to false, every event type with
	// its where map, manual; plus names of exactly 80 runes.
	good := []acceptedTrigger{
		{"24-char button", "name: T\ntrigger:\n  button: {label: \"" + strings.Repeat("x", 24) + "\", confirm: true}\n", "T",
			Trigger{Kind: TriggerButton, Button: &ButtonTrigger{Label: strings.Repeat("x", 24), Confirm: true}}},
		{"trimmed label", "name: T\ntrigger:\n  button: {label: \"  Ship  \"}\n", "T",
			Trigger{Kind: TriggerButton, Button: &ButtonTrigger{Label: "Ship"}}},
		{"manual", baseFrontmatter, "Test", Trigger{Kind: TriggerManual}},
		{"80-rune name", "name: " + strings.Repeat("n", 80) + "\ntrigger:\n  manual: true\n", strings.Repeat("n", 80), Trigger{Kind: TriggerManual}},
		{"80-rune multibyte name", "name: " + strings.Repeat("я", 80) + "\ntrigger:\n  manual: true\n", strings.Repeat("я", 80), Trigger{Kind: TriggerManual}},
	}
	for _, typ := range EventTypes {
		good = append(good, acceptedTrigger{"event " + typ, "name: T\ntrigger:\n  event:\n    type: " + typ + "\n    where: {channel: \"rel*\"}\n", "T",
			Trigger{Kind: TriggerEvent, Event: &EventTrigger{Type: typ, Where: map[string]string{"channel": "rel*"}}}})
	}
	for _, c := range good {
		r := mustParse(t, recipeWith(c.frontmatter, "x\n"), Scope{Kind: ScopePersonal})
		if r.Name != c.name || !reflect.DeepEqual(r.Trigger, c.trigger) {
			t.Errorf("%s: name %q trigger %+v, want %q %+v", c.label, r.Name, r.Trigger, c.name, c.trigger)
		}
	}
}

func TestRecipe_TooLarge(t *testing.T) {
	base := recipeWith(baseFrontmatter, "x\n")
	padded := append(append([]byte{}, base...), bytes.Repeat([]byte("a"), MaxRecipeBytes+1-len(base))...)
	if len(padded) != MaxRecipeBytes+1 {
		t.Fatalf("fixture size = %d", len(padded))
	}
	wantParseError(t, padded, "262144")

	exact := padded[:MaxRecipeBytes]
	if _, err := ParseRecipe("ok", exact, Scope{Kind: ScopePersonal}); err != nil {
		t.Errorf("exactly MaxRecipeBytes: %v", err)
	}
}

func TestRecipe_CRLFAndBOMNormalised(t *testing.T) {
	lf := readFixture(t, "ok.md")
	crlf := append([]byte("\xef\xbb\xbf"), bytes.ReplaceAll(lf, []byte("\n"), []byte("\r\n"))...)
	if bytes.Equal(lf, crlf) || !bytes.Contains(crlf, []byte("\r\n")) {
		t.Fatal("twin fixture is not CRLF+BOM")
	}

	scope := Scope{Kind: ScopeWorkbench, WorkbenchID: 7}
	a := mustParse(t, lf, scope)
	b := mustParse(t, crlf, scope)
	if !reflect.DeepEqual(a, b) {
		t.Errorf("CRLF+BOM twin parses differently:\nlf:   %+v\ncrlf: %+v", a, b)
	}
	if ApprovalHash(a) != ApprovalHash(b) {
		t.Error("CRLF+BOM twin has a different approval hash")
	}
	if strings.Contains(b.Script, "\r") || strings.Contains(b.Description, "\r") || strings.HasPrefix(b.Name, "\xef\xbb\xbf") {
		t.Errorf("CR or BOM survived: %+v", b)
	}
	if ContentHash(lf) == ContentHash(crlf) {
		t.Error("ContentHash must hash the raw bytes")
	}
	// BOM alone (LF endings) parses too.
	mustParse(t, append([]byte("\xef\xbb\xbf"), lf...), scope)
}

func TestRecipe_InvalidUTF8Refused(t *testing.T) {
	lf := readFixture(t, "ok.md")
	bad := bytes.Replace(lf, []byte("Summarises"), []byte("Summ\xffarises"), 1)
	line, msg := wantParseError(t, bad, "invalid UTF-8")
	if !strings.Contains(msg, "ok.md") {
		t.Errorf("error does not name the file: %q", msg)
	}
	if line != 10 {
		t.Errorf("line = %d, want 10", line)
	}
}

func TestRecipe_FrontmatterShape(t *testing.T) {
	wantParseError(t, []byte("name: T\n```js\nx\n```\n"), "frontmatter")
	wantParseError(t, []byte("---\nname: T\ntrigger:\n  manual: true\n```js\nx\n```\n"), "frontmatter")
	wantParseError(t, []byte("---\n- a\n- b\n---\n```js\nx\n```\n"), "mapping")
	wantParseError(t, []byte("---\nname: T\nname: U\ntrigger:\n  manual: true\n---\n```js\nx\n```\n"), "name")
	wantParseError(t, []byte("---\nname: [\n---\n```js\nx\n```\n"), "frontmatter")
}

// TestApprovalHash_IgnoresNameChangesOnScriptPermissionsScheduleBudget: the
// approval hash binds the script, permissions, outputs, scope, trigger, missed
// policy, budget and concurrency (D26, ask #294), not the name, description,
// a button's label or the pause timeout.
func TestApprovalHash_IgnoresNameChangesOnScriptPermissionsScheduleBudget(t *testing.T) {
	personal := Scope{Kind: ScopePersonal}
	baseFM := "name: A\ntrigger:\n  manual: true\npermissions: [llm:light, gmail:read@work]\noutputs: [inbox]\n"
	baseScript := "log(1);\n"
	base := ApprovalHash(mustParse(t, recipeWith(baseFM, baseScript), personal))
	if len(base) != 64 {
		t.Fatalf("hash %q is not hex sha256", base)
	}

	same := map[string][]byte{
		"name":        recipeWith(strings.Replace(baseFM, "name: A", "name: B", 1), baseScript),
		"description": []byte("---\n" + baseFM + "---\nOther words.\n\n```js\n" + baseScript + "```\nMore.\n"),
		"pause":       recipeWith(baseFM+"pause_timeout_hours: 9\n", baseScript),
		"perm order":  recipeWith(strings.Replace(baseFM, "[llm:light, gmail:read@work]", "[gmail:read@work, llm:light]", 1), baseScript),
	}
	for label, data := range same {
		if got := ApprovalHash(mustParse(t, data, personal)); got != base {
			t.Errorf("%s changed the hash", label)
		}
	}

	differ := map[string][]byte{
		"script byte": recipeWith(baseFM, "log(2);\n"),
		"permission":  recipeWith(strings.Replace(baseFM, "gmail:read@work]", "gmail:read@work, llm:strong]", 1), baseScript),
		"output":      recipeWith(strings.Replace(baseFM, "[inbox]", "[inbox, report]", 1), baseScript),
		"trigger":     recipeWith(strings.Replace(baseFM, "manual: true", "schedule: \"0 9 * * *\"", 1), baseScript),
		"budget":      recipeWith(baseFM+"budget: {tokens: 9000, minutes: 9}\n", baseScript),
		"tokens only": recipeWith(baseFM+"budget: {tokens: 9000}\n", baseScript),
		"concurrency": recipeWith(baseFM+"concurrency: 3\n", baseScript),
		"missed":      recipeWith(baseFM+"missed: skip\n", baseScript),
		"button":      recipeWith(strings.Replace(baseFM, "manual: true", "button: {label: Go}", 1), baseScript),
	}
	for label, data := range differ {
		if got := ApprovalHash(mustParse(t, data, personal)); got == base {
			t.Errorf("%s did not change the hash", label)
		}
	}
	wb := ApprovalHash(mustParse(t, recipeWith(baseFM, baseScript), Scope{Kind: ScopeWorkbench, WorkbenchID: 1}))
	if wb == base {
		t.Error("scope personal -> workbench:1 did not change the hash")
	}

	// Empty lists hash as [] (never null), so nil and empty are the same recipe.
	empty := &Recipe{Scope: personal, Script: "x"}
	emptyLists := &Recipe{Scope: personal, Script: "x", Permissions: []string{}, Outputs: []string{}}
	if ApprovalHash(empty) != ApprovalHash(emptyLists) {
		t.Error("nil and empty lists hash differently")
	}
}

func TestScope_String(t *testing.T) {
	if got := (Scope{Kind: ScopePersonal}).String(); got != "personal" {
		t.Errorf("personal = %q", got)
	}
	if got := (Scope{Kind: ScopeWorkbench, WorkbenchID: 12}).String(); got != "workbench:12" {
		t.Errorf("workbench = %q", got)
	}
}

func TestParseError_Format(t *testing.T) {
	if got := (&ParseError{Line: 3, Msg: "bad"}).Error(); got != "line 3: bad" {
		t.Errorf("got %q", got)
	}
	if got := (&ParseError{Msg: "bad"}).Error(); got != "bad" {
		t.Errorf("got %q", got)
	}
}

func TestApprovalHash_GoldenCanonicalBytes(t *testing.T) {
	r := &Recipe{
		Scope:       Scope{Kind: ScopeWorkbench, WorkbenchID: 3},
		Permissions: []string{"llm:light", "gmail:read@work", "llm:light"},
		Outputs:     []string{"report", "inbox", "inbox"},
		Script:      "if (a < b && c > d) { log(\"Привет — ok\"); }\n",
		Trigger: Trigger{Kind: TriggerEvent, Event: &EventTrigger{Type: "jira.issue_changed",
			Where: map[string]string{"status": "<Done>", "project": "ACME"}}},
		Missed:      MissedSkip,
		Budget:      Budget{Tokens: 20000, Minutes: 5},
		Concurrency: 2,
	}
	// The hex below was computed outside Go (Python hashlib over these bytes).
	const wantCanonical = `{"permissions":["gmail:read@work","llm:light"],"outputs":["inbox","report"],` +
		`"scope":"workbench:3","script":"if (a < b && c > d) { log(\"Привет — ok\"); }\n",` +
		`"trigger":{"event":{"type":"jira.issue_changed","where":{"project":"ACME","status":"<Done>"}}},` +
		`"missed":"skip","budget":{"tokens":20000,"minutes":5},"concurrency":2}`
	if got := string(approvalCanonical(r)); got != wantCanonical {
		t.Fatalf("canonical bytes:\n got: %s\nwant: %s", got, wantCanonical)
	}
	const wantHex = "15702e51b067d78bef2920774371c170660138f734f370941487d1829b1b3451"
	if got := ApprovalHash(r); got != wantHex {
		t.Fatalf("ApprovalHash = %s, want %s", got, wantHex)
	}
}

// TestApprovalHash_ButtonLabelIsCosmetic: renaming a button keeps the hash;
// its confirm flag changes it (D26, ask #294).
func TestApprovalHash_ButtonLabelIsCosmetic(t *testing.T) {
	personal := Scope{Kind: ScopePersonal}
	fm := func(button string) []byte {
		return recipeWith("name: A\ntrigger:\n  button: "+button+"\npermissions: [llm:light]\n", "log(1);\n")
	}
	base := ApprovalHash(mustParse(t, fm("{label: Go}"), personal))
	if got := ApprovalHash(mustParse(t, fm("{label: Run it now}"), personal)); got != base {
		t.Error("a label rename changed the hash")
	}
	if got := ApprovalHash(mustParse(t, fm("{label: Go, confirm: true}"), personal)); got == base {
		t.Error("turning confirm on did not change the hash")
	}
	if got := string(approvalCanonical(mustParse(t, fm("{label: Go, confirm: true}"), personal))); !strings.Contains(got, `"trigger":{"button":{"confirm":true}}`) {
		t.Errorf("canonical bytes carry the label or lose confirm: %s", got)
	}
}

func TestApprovalHash_DuplicateEntriesKeepTheHash(t *testing.T) {
	base := &Recipe{Scope: Scope{Kind: ScopePersonal}, Script: "x", Permissions: []string{"llm:light"}, Outputs: []string{"inbox"}}
	dup := &Recipe{Scope: Scope{Kind: ScopePersonal}, Script: "x", Permissions: []string{"llm:light", "llm:light"}, Outputs: []string{"inbox", "inbox"}}
	if ApprovalHash(base) != ApprovalHash(dup) {
		t.Error("a duplicated permission or output changed the hash")
	}
}

func TestRecipe_TildeAndCaseInsensitiveScriptFences(t *testing.T) {
	for _, open := range []string{"~~~js", "~~~javascript", "```JS", "```JavaScript", "~~~~Js"} {
		closer := "```"
		if strings.HasPrefix(open, "~") {
			closer = strings.Repeat("~", strings.Count(open, "~"))
		}
		data := []byte("---\n" + baseFrontmatter + "---\n" + open + "\nlog(1);\n" + closer + "\n")
		r := mustParse(t, data, Scope{Kind: ScopePersonal})
		if r.Script != "log(1);\n" || r.ScriptLine != 7 {
			t.Errorf("%s: script=%q line=%d", open, r.Script, r.ScriptLine)
		}
	}
	// A tilde fence is not closed by backticks.
	wantParseError(t, []byte("---\n"+baseFrontmatter+"---\n~~~js\nlog(1);\n```\n"), "not closed")

	mixed := []byte("---\n" + baseFrontmatter + "---\n```js\nlog(1);\n```\n~~~JS\nlog(2);\n~~~\n")
	if line, _ := wantParseError(t, mixed, "second"); line != 9 {
		t.Errorf("mixed second block line = %d, want 9", line)
	}
}

func TestRecipe_ScopeValidated(t *testing.T) {
	data := readFixture(t, "ok.md")
	for _, s := range []Scope{{}, {Kind: "team"}, {Kind: ScopeWorkbench}, {Kind: ScopeWorkbench, WorkbenchID: -1}, {Kind: ScopePersonal, WorkbenchID: 2}} {
		_, err := ParseRecipe("ok", data, s)
		var pe *ParseError
		if !errors.As(err, &pe) || !strings.Contains(pe.Msg, "scope") {
			t.Errorf("scope %+v: want a scope *ParseError, got %v", s, err)
		}
	}
	if r := mustParse(t, data, Scope{Kind: ScopeWorkbench, WorkbenchID: 1}); r.Scope.String() != "workbench:1" {
		t.Errorf("scope = %s", r.Scope)
	}
}

func TestRecipe_DegenerateFiles(t *testing.T) {
	cases := []struct {
		label    string
		data     string
		contains string
		line     int
	}{
		{"empty file", "", "frontmatter", 1},
		{"only a newline", "\n", "frontmatter", 1},
		{"empty frontmatter", "---\n---\n```js\nx\n```\n", "mapping", 2},
		{"blank frontmatter", "---\n\n\n---\n```js\nx\n```\n", "mapping", 2},
		{"empty js block", "---\n" + baseFrontmatter + "---\n```js\n```\n", "script is empty", 6},
		{"blank js block", "---\n" + baseFrontmatter + "---\n```js\n  \n\n```\n", "script is empty", 6},
		{"frontmatter only", "---\n" + baseFrontmatter + "---\n", "found none", 6},
	}
	for _, c := range cases {
		_, err := ParseRecipe("ok", []byte(c.data), Scope{Kind: ScopePersonal})
		var pe *ParseError
		if !errors.As(err, &pe) {
			t.Errorf("%s: want *ParseError, got %T: %v", c.label, err, err)
			continue
		}
		if !strings.Contains(pe.Msg, c.contains) || pe.Line != c.line {
			t.Errorf("%s: got %q (line %d), want %q on line %d", c.label, pe.Msg, pe.Line, c.contains, c.line)
		}
	}
}

func TestRecipe_LoneCRNormalised(t *testing.T) {
	lf := readFixture(t, "ok.md")
	cr := bytes.ReplaceAll(lf, []byte("\n"), []byte("\r"))
	scope := Scope{Kind: ScopePersonal}
	a, b := mustParse(t, lf, scope), mustParse(t, cr, scope)
	if !reflect.DeepEqual(a, b) || ApprovalHash(a) != ApprovalHash(b) {
		t.Errorf("lone-CR twin parses differently:\nlf: %+v\ncr: %+v", a, b)
	}
}
