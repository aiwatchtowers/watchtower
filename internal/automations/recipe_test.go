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

	if r.Slug != "ok" || r.Name != "New mail summary" {
		t.Errorf("slug/name = %q/%q", r.Slug, r.Name)
	}
	if r.Trigger.Kind != TriggerSchedule || r.Trigger.Schedule != "0 9 * * 1-5" {
		t.Errorf("trigger = %+v", r.Trigger)
	}
	if r.Trigger.Button != nil || r.Trigger.Event != nil {
		t.Errorf("unexpected button/event: %+v", r.Trigger)
	}
	if !reflect.DeepEqual(r.Permissions, []string{"gmail:read@work", "llm:light"}) {
		t.Errorf("permissions = %v", r.Permissions)
	}
	if !reflect.DeepEqual(r.Outputs, []string{"inbox"}) {
		t.Errorf("outputs = %v", r.Outputs)
	}
	if r.Budget != (Budget{Tokens: 50000, Minutes: 5}) {
		t.Errorf("budget = %+v", r.Budget)
	}
	if r.Concurrency != 1 || r.Missed != MissedRunOnce || r.PauseTimeoutHours != 72 {
		t.Errorf("defaults: concurrency=%d missed=%q pause=%d", r.Concurrency, r.Missed, r.PauseTimeoutHours)
	}
	if r.ScriptLine != 13 {
		t.Errorf("ScriptLine = %d, want 13", r.ScriptLine)
	}
	wantScript := "const mail = tool(\"list_emails\", { account: \"work\" });\n" +
		"output.inbox({ title: \"Mail\", body: llm(\"Summarise\", mail) });\n"
	if r.Script != wantScript {
		t.Errorf("script = %q", r.Script)
	}
	if strings.Contains(r.Description, "```") || strings.Contains(r.Description, "tool(") {
		t.Errorf("description contains the block: %q", r.Description)
	}
	if !strings.Contains(r.Description, "Summarises new mail") || !strings.Contains(r.Description, "Shown on the card") {
		t.Errorf("description = %q", r.Description)
	}
	if r.Scope != (Scope{Kind: ScopePersonal}) {
		t.Errorf("scope = %+v", r.Scope)
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

func TestRecipe_BudgetBounds(t *testing.T) {
	bad := []string{
		"budget: {tokens: 999}\n",
		"budget: {tokens: 2000001}\n",
		"budget: {minutes: 0}\n",
		"budget: {minutes: 61}\n",
		"concurrency: 0\n",
		"concurrency: 5\n",
		"pause_timeout_hours: 0\n",
		"pause_timeout_hours: 169\n",
		"budget: {tokens: lots}\n",
		"missed: sometimes\n",
	}
	for _, fm := range bad {
		if _, err := ParseRecipe("ok", recipeWith(baseFrontmatter+fm, "x\n"), Scope{Kind: ScopePersonal}); err == nil {
			t.Errorf("%q: want error", strings.TrimSpace(fm))
		}
	}

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
}

func TestRecipe_TriggerExactlyOne(t *testing.T) {
	bad := map[string]string{
		"none":          "name: T\n",
		"empty map":     "name: T\ntrigger: {}\n",
		"two kinds":     "name: T\ntrigger:\n  manual: true\n  schedule: \"0 9 * * *\"\n",
		"bad cron":      "name: T\ntrigger:\n  schedule: \"61 * * * *\"\n",
		"six fields":    "name: T\ntrigger:\n  schedule: \"0 0 9 * * *\"\n",
		"descriptor":    "name: T\ntrigger:\n  schedule: \"@daily\"\n",
		"tz prefix":     "name: T\ntrigger:\n  schedule: \"CRON_TZ=UTC 0 9 * * *\"\n",
		"bad event":     "name: T\ntrigger:\n  event: {type: foo.bar}\n",
		"no event type": "name: T\ntrigger:\n  event: {where: {channel: x}}\n",
		"empty label":   "name: T\ntrigger:\n  button: {label: \"\"}\n",
		"long label":    "name: T\ntrigger:\n  button: {label: \"" + strings.Repeat("x", 25) + "\"}\n",
		"manual false":  "name: T\ntrigger:\n  manual: false\n",
		"no name":       "trigger:\n  manual: true\n",
		"long name":     "name: " + strings.Repeat("n", 81) + "\ntrigger:\n  manual: true\n",
	}
	for label, fm := range bad {
		if _, err := ParseRecipe("ok", recipeWith(fm, "x\n"), Scope{Kind: ScopePersonal}); err == nil {
			t.Errorf("%s: want error", label)
		}
	}

	r := mustParse(t, recipeWith("name: T\ntrigger:\n  button: {label: \""+strings.Repeat("x", 24)+"\", confirm: true}\n", "x\n"), Scope{Kind: ScopePersonal})
	if r.Trigger.Kind != TriggerButton || r.Trigger.Button == nil || !r.Trigger.Button.Confirm || len(r.Trigger.Button.Label) != 24 {
		t.Errorf("button = %+v", r.Trigger)
	}
	r = mustParse(t, recipeWith("name: T\ntrigger:\n  button: {label: Ship}\n", "x\n"), Scope{Kind: ScopePersonal})
	if r.Trigger.Button.Confirm {
		t.Error("button.confirm default must be false")
	}
	for _, typ := range EventTypes {
		r = mustParse(t, recipeWith("name: T\ntrigger:\n  event:\n    type: "+typ+"\n    where: {channel: \"rel*\"}\n", "x\n"), Scope{Kind: ScopePersonal})
		if r.Trigger.Kind != TriggerEvent || r.Trigger.Event.Type != typ || r.Trigger.Event.Where["channel"] != "rel*" {
			t.Errorf("event %s = %+v", typ, r.Trigger.Event)
		}
	}
	r = mustParse(t, recipeWith(baseFrontmatter, "x\n"), Scope{Kind: ScopePersonal})
	if r.Trigger.Kind != TriggerManual {
		t.Errorf("manual = %+v", r.Trigger)
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

func TestApprovalHash_IgnoresNameTriggerBudgetChangesOnScriptAndPermissions(t *testing.T) {
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
		"trigger":     recipeWith(strings.Replace(baseFM, "manual: true", "schedule: \"0 9 * * *\"", 1), baseScript),
		"missed":      recipeWith(baseFM+"missed: skip\n", baseScript),
		"budget":      recipeWith(baseFM+"budget: {tokens: 9000, minutes: 9}\n", baseScript),
		"concurrency": recipeWith(baseFM+"concurrency: 3\n", baseScript),
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
	}
	const wantCanonical = `{"permissions":["gmail:read@work","llm:light"],"outputs":["inbox","report"],` +
		`"scope":"workbench:3","script":"if (a < b && c > d) { log(\"Привет — ok\"); }\n"}`
	if got := string(approvalCanonical(r)); got != wantCanonical {
		t.Fatalf("canonical bytes:\n got: %s\nwant: %s", got, wantCanonical)
	}
	const wantHex = "0613533506afa87f9d2365a0cd7636764f552f46c4db2a40c7214e01f446815c"
	if got := ApprovalHash(r); got != wantHex {
		t.Fatalf("ApprovalHash = %s, want %s", got, wantHex)
	}
}

func TestApprovalHash_DuplicateEntriesKeepTheHash(t *testing.T) {
	base := &Recipe{Scope: Scope{Kind: ScopePersonal}, Script: "x", Permissions: []string{"llm:light"}, Outputs: []string{"inbox"}}
	dup := &Recipe{Scope: Scope{Kind: ScopePersonal}, Script: "x", Permissions: []string{"llm:light", "llm:light"}, Outputs: []string{"inbox", "inbox"}}
	if ApprovalHash(base) != ApprovalHash(dup) {
		t.Error("a duplicated permission or output changed the hash")
	}
}
