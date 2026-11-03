package blocks_test

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/dop251/goja"

	"watchtower/internal/automations/blocks"
	"watchtower/internal/db"
)

const fn = "output.inbox"

// js evaluates a JS expression and returns goja's exported value, the
// shape the SDK hands to the package.
func js(t testing.TB, expr string) any {
	t.Helper()
	v, err := goja.New().RunString("(" + expr + ")")
	if err != nil {
		t.Fatalf("evaluating %.80s: %v", expr, err)
	}
	return v.Export()
}

func validate(t testing.TB, expr string, opts blocks.Options) (blocks.Document, error) {
	t.Helper()
	return blocks.Validate(fn, js(t, expr), opts)
}

func mustValidate(t testing.TB, expr string) blocks.Document {
	t.Helper()
	d, err := validate(t, expr, blocks.Options{})
	if err != nil {
		t.Fatalf("Validate(%.120s): %v", expr, err)
	}
	return d
}

// wantRefused wants a *blocks.Error whose message contains want.
func wantRefused(t *testing.T, expr string, opts blocks.Options, want string) {
	t.Helper()
	_, err := validate(t, expr, opts)
	var be *blocks.Error
	if !errors.As(err, &be) {
		t.Fatalf("Validate(%.120s) = %v; want a *blocks.Error", expr, err)
	}
	if !strings.Contains(be.Msg, want) {
		t.Fatalf("Validate(%.120s) = %q; want it to contain %q", expr, be.Msg, want)
	}
}

// rows is a JS array expression of n list rows.
func rows(n int, row string) string {
	return fmt.Sprintf(`Array.from({length: %d}, (_, i) => (%s))`, n, row)
}

func TestValidate_LimitsAtAndPastTheCap(t *testing.T) {
	cases := []struct {
		name     string
		at, past string
		want     string
	}{
		{"blocks", `Array(40).fill({type: "text", markdown: "x"})`, `Array(41).fill({type: "text", markdown: "x"})`, "blocks has 41 blocks; the limit is 40"},
		{"heading text", `[{type: "heading", text: "é".repeat(200)}]`, `[{type: "heading", text: "é".repeat(201)}]`, "blocks[0].text is 201 characters; the limit is 200"},
		{"markdown bytes", `[{type: "text", markdown: "x".repeat(16384)}]`, `[{type: "text", markdown: "x".repeat(16385)}]`, "blocks[0].markdown is 16385 bytes; the limit is 16384"},
		{"list title", `[{type: "list", title: "x".repeat(200), rows: []}]`, `[{type: "list", title: "x".repeat(201), rows: []}]`, "blocks[0].title is 201 characters"},
		{"list empty", `[{type: "list", empty: "x".repeat(200), rows: []}]`, `[{type: "list", empty: "x".repeat(201), rows: []}]`, "blocks[0].empty is 201 characters"},
		{"list rows", `[{type: "list", rows: ` + rows(200, `{title: "r"}`) + `}]`, `[{type: "list", rows: ` + rows(201, `{title: "r"}`) + `}]`, "blocks[0].rows has 201 rows; the limit is 200"},
		{"row title", `[{type: "list", rows: [{title: "x".repeat(300)}]}]`, `[{type: "list", rows: [{title: "x".repeat(301)}]}]`, "rows[0].title is 301 characters"},
		{"row subtitle", `[{type: "list", rows: [{title: "t", subtitle: "x".repeat(500)}]}]`, `[{type: "list", rows: [{title: "t", subtitle: "x".repeat(501)}]}]`, "rows[0].subtitle is 501 characters"},
		{"badge text", `[{type: "list", rows: [{title: "t", badge: {text: "x".repeat(40)}}]}]`, `[{type: "list", rows: [{title: "t", badge: {text: "x".repeat(41)}}]}]`, "rows[0].badge.text is 41 characters"},
		{"row actions", `[{type: "list", rows: [{title: "t", actions: Array(3).fill({label: "a", chat: "x"})}]}]`, `[{type: "list", rows: [{title: "t", actions: Array(4).fill({label: "a", chat: "x"})}]}]`, "rows[0].actions has 4 actions; the limit is 3"},
		{"columns", `[{type: "table", columns: Array(6).fill({title: "c"}), rows: []}]`, `[{type: "table", columns: Array(7).fill({title: "c"}), rows: []}]`, "blocks[0].columns has 7 columns; the limit is 6"},
		{"column title", `[{type: "table", columns: [{title: "x".repeat(60)}], rows: []}]`, `[{type: "table", columns: [{title: "x".repeat(61)}], rows: []}]`, "columns[0].title is 61 characters"},
		{"table rows", `[{type: "table", columns: [{title: "c"}], rows: Array(100).fill(["x"])}]`, `[{type: "table", columns: [{title: "c"}], rows: Array(101).fill(["x"])}]`, "blocks[0].rows has 101 rows; the limit is 100"},
		{"cell", `[{type: "table", columns: [{title: "c"}], rows: [["x".repeat(200)]]}]`, `[{type: "table", columns: [{title: "c"}], rows: [["x".repeat(201)]]}]`, "rows[0][0] is 201 characters; the limit is 200"},
		{"cell object", `[{type: "table", columns: [{title: "c"}], rows: [[{text: "x".repeat(200)}]]}]`, `[{type: "table", columns: [{title: "c"}], rows: [[{text: "x".repeat(201)}]]}]`, "rows[0][0].text is 201 characters"},
		{"person name", `[{type: "person", name: "x".repeat(120)}]`, `[{type: "person", name: "x".repeat(121)}]`, "blocks[0].name is 121 characters"},
		{"person role", `[{type: "person", name: "n", role: "x".repeat(120)}]`, `[{type: "person", name: "n", role: "x".repeat(121)}]`, "blocks[0].role is 121 characters"},
		{"person lines", `[{type: "person", name: "n", lines: Array(10).fill("l")}]`, `[{type: "person", name: "n", lines: Array(11).fill("l")}]`, "blocks[0].lines has 11 lines; the limit is 10"},
		{"person line", `[{type: "person", name: "n", lines: ["x".repeat(300)]}]`, `[{type: "person", name: "n", lines: ["x".repeat(301)]}]`, "lines[0] is 301 characters"},
		{"metrics", `[{type: "metrics", items: Array(6).fill({label: "l", value: "v"})}]`, `[{type: "metrics", items: Array(7).fill({label: "l", value: "v"})}]`, "blocks[0].items has 7 items; the limit is 6"},
		{"metric label", `[{type: "metrics", items: [{label: "x".repeat(40), value: "v"}]}]`, `[{type: "metrics", items: [{label: "x".repeat(41), value: "v"}]}]`, "items[0].label is 41 characters"},
		{"metric value", `[{type: "metrics", items: [{label: "l", value: "x".repeat(24)}]}]`, `[{type: "metrics", items: [{label: "l", value: "x".repeat(25)}]}]`, "items[0].value is 25 characters"},
		{"metric hint", `[{type: "metrics", items: [{label: "l", value: "v", hint: "x".repeat(120)}]}]`, `[{type: "metrics", items: [{label: "l", value: "v", hint: "x".repeat(121)}]}]`, "items[0].hint is 121 characters"},
		{"link title", `[{type: "link", title: "x".repeat(200), url: "https://example.com"}]`, `[{type: "link", title: "x".repeat(201), url: "https://example.com"}]`, "blocks[0].title is 201 characters"},
		{"link subtitle", `[{type: "link", title: "t", url: "https://example.com", subtitle: "x".repeat(300)}]`, `[{type: "link", title: "t", url: "https://example.com", subtitle: "x".repeat(301)}]`, "blocks[0].subtitle is 301 characters"},
		{"link url", `[{type: "link", title: "t", url: "https://example.com/" + "a".repeat(2048 - 20)}]`, `[{type: "link", title: "t", url: "https://example.com/" + "a".repeat(2048 - 19)}]`, "blocks[0].url is 2049 bytes; the limit is 2048"},
		{"actions block", `[{type: "actions", actions: Array(4).fill({label: "a", chat: "x"})}]`, `[{type: "actions", actions: Array(5).fill({label: "a", chat: "x"})}]`, "blocks[0].actions has 5 actions; the limit is 4"},
		{"total rows", `Array(5).fill({type: "list", rows: ` + rows(100, `{title: "r"}`) + `})`, `Array(5).fill({type: "list", rows: ` + rows(100, `{title: "r"}`) + `}).concat([{type: "table", columns: [{title: "c"}], rows: [["x"]]}])`, "the card has 501 list and table rows; the limit is 500"},
		{"target title", `[{type: "actions", actions: [{label: "a", target: {title: "é".repeat(200)}}]}]`, `[{type: "actions", actions: [{label: "a", target: {title: "é".repeat(201)}}]}]`, "actions[0].target.title must be a non-empty string of at most 200 characters"},
		{"target intent", `[{type: "actions", actions: [{label: "a", target: {title: "t", intent: "x".repeat(1000)}}]}]`, `[{type: "actions", actions: [{label: "a", target: {title: "t", intent: "x".repeat(1001)}}]}]`, "actions[0].target.intent is 1001 characters; the limit is 1000"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			mustValidate(t, c.at)
			wantRefused(t, c.past, blocks.Options{}, c.want)
		})
	}
}

func TestValidate_FlattenedActionCap(t *testing.T) {
	// 16 rows × 3 actions + one actions block of 2 = 50 block actions.
	expr := `[{type: "list", rows: ` + rows(16, `{title: "r", actions: Array(3).fill({label: "a", chat: "x"})}`) +
		`}, {type: "actions", actions: Array(2).fill({label: "a", chat: "x"})}]`
	if _, err := validate(t, expr, blocks.Options{}); err != nil {
		t.Fatalf("50 actions refused: %v", err)
	}
	wantRefused(t, expr, blocks.Options{CardActions: 1}, "the card has 51 actions; the limit is 50")
	if _, err := validate(t, expr, blocks.Options{CardActions: 0}); err != nil {
		t.Fatal(err)
	}
}

func TestValidate_DocumentBytesCap(t *testing.T) {
	doc := func(k int) string {
		return fmt.Sprintf(`Array(7).fill({type: "text", markdown: "x".repeat(16384)}).concat([{type: "text", markdown: "y".repeat(%d)}])`, k)
	}
	d := mustValidate(t, doc(1))
	b, err := d.Canonical()
	if err != nil {
		t.Fatal(err)
	}
	exact := blocks.MaxBlocksBytes - len(b) + 1
	d = mustValidate(t, doc(exact))
	if b, _ = d.Canonical(); len(b) != blocks.MaxBlocksBytes {
		t.Fatalf("document is %d bytes; want exactly %d", len(b), blocks.MaxBlocksBytes)
	}
	wantRefused(t, doc(exact+1), blocks.Options{}, fmt.Sprintf("blocks is %d bytes; the limit is %d", blocks.MaxBlocksBytes+1, blocks.MaxBlocksBytes))
}

func TestValidate_DegenerateInputs(t *testing.T) {
	// Valid degenerate documents.
	if d := mustValidate(t, `[]`); len(d.Blocks) != 0 || d.V != 1 {
		t.Fatalf("empty = %+v", d)
	}
	d := mustValidate(t, `[{type: "list", rows: []}, {type: "table", columns: [{title: "c"}], rows: []}]`)
	if d.Blocks[0].List.Empty != blocks.DefaultListEmpty || d.Blocks[0].List.Rows == nil || d.Blocks[1].Table.Rows == nil {
		t.Fatalf("zero-row blocks = %+v %+v", d.Blocks[0].List, d.Blocks[1].Table)
	}
	d = mustValidate(t, `[{type: "list", rows: `+rows(200, `{title: "r" + i, ref: {kind: "track", id: i + 1}}`)+`}]`)
	if r := d.Blocks[0].List.Rows; len(r) != 200 || r[199].Ref.ID != 200 {
		t.Fatalf("200 refs = %d rows", len(r))
	}
	// Refused degenerate inputs, each with a path.
	for expr, want := range map[string]string{
		`null`:                                 "blocks must be an array of blocks",
		`{type: "text"}`:                       "blocks must be an array of blocks",
		`[null]`:                               "blocks[0] must be an object",
		`[[]]`:                                 "blocks[0] must be an object",
		`[{type: 5}]`:                          "blocks[0]: a block needs a type",
		`[{type: "list", rows: null}]`:         "blocks[0].rows must be an array",
		`[{type: "list", rows: [null]}]`:       "blocks[0].rows[0] must be an object",
		`[{type: "list", rows: [{title: 7}]}]`: "blocks[0].rows[0].title must be a non-empty string",
		`[{type: "list", rows: [{title: "t", badge: null}]}]`:                        "blocks[0].rows[0].badge must be an object",
		`[{type: "list", rows: [{title: "t", tone: 1}]}]`:                            "blocks[0].rows[0].tone must be one of",
		`[{type: "list", rows: [{title: "t", ref: {kind: "track", id: NaN}}]}]`:      "ref.id must be a positive integer",
		`[{type: "list", rows: [{title: "t", ref: {kind: "track", id: Infinity}}]}]`: "ref.id must be a positive integer",
		`[{type: "list", rows: [{title: "t", ref: {kind: "track", id: 1.5}}]}]`:      "ref.id must be a positive integer",
		`[{type: "heading", text: "t", level: NaN}]`:                                 "blocks[0].level must be 1 or 2",
		`[{type: "metrics", items: [{label: "l", value: NaN}]}]`:                     "items[0].value must be a non-empty string",
		`[{type: "metrics", items: [{label: "l", value: 3}]}]`:                       "items[0].value must be a non-empty string",
		`[{type: "table", columns: [{title: "c"}], rows: [null]}]`:                   "blocks[0].rows[0] must be an array of cells",
		`[{type: "table", columns: [{title: "c"}], rows: [[5]]}]`:                    "blocks[0].rows[0][0] must be an object",
		`[{type: "table", columns: [{title: "c"}], rows: [[]]}]`:                     "has 0 cells; the table has 1 columns",
		`[{type: "person", name: "n", lines: [""]}]`:                                 "blocks[0].lines[0] must be a non-empty string",
		`[{type: "text", markdown: "   "}]`:                                          "blocks[0].markdown must be a non-empty string",
		`[{type: "link", title: "t"}]`:                                               "blocks[0].url must be an http",
		`[{type: "link", title: "t", url: 5}]`:                                       "blocks[0].url must be an http",
		`[{type: "actions"}]`:                                                        "blocks[0].actions must be an array",
		`[{type: "actions", actions: [null]}]`:                                       "blocks[0].actions[0] must be an object",
	} {
		t.Run(expr, func(t *testing.T) { wantRefused(t, expr, blocks.Options{}, want) })
	}
}

func TestValidate_ActionRefsOnlyBuiltIn(t *testing.T) {
	for _, kind := range []string{"action", "reminder"} {
		expr := `[{type: "list", rows: [{title: "t", ref: {kind: "` + kind + `", id: 3}}]}]`
		wantRefused(t, expr, blocks.Options{}, "ref is only for built-in automations")
		if _, err := validate(t, expr, blocks.Options{BuiltIn: true}); err != nil {
			t.Fatalf("built-in %s ref refused: %v", kind, err)
		}
	}
	for _, kind := range []string{"inbox_item", "track", "idea"} {
		mustValidate(t, `[{type: "list", rows: [{title: "t", ref: {kind: "`+kind+`", id: 3}}]}]`)
	}
}

func TestValidate_AllowKindRefusalSurfaces(t *testing.T) {
	denied := errors.New("permission denied: the recipe needs output:target")
	var asked []string
	opts := blocks.Options{AllowKind: func(kind string) error {
		asked = append(asked, kind)
		if kind == db.InboxActionTarget {
			return denied
		}
		return nil
	}}
	_, err := validate(t, `[{type: "list", rows: [{title: "t", actions: [{label: "a", chat: "x"}, {label: "b", target: {title: "t"}}]}]}]`, opts)
	if !errors.Is(err, denied) {
		t.Fatalf("err = %v; want the AllowKind error unchanged", err)
	}
	if fmt.Sprint(asked) != "[chat target]" {
		t.Fatalf("asked = %v", asked)
	}
	_, err = blocks.ValidateAction(fn, "actions", 0, js(t, `{label: "r", reply: "v"}`), blocks.Options{AllowKind: func(string) error { return denied }})
	if !errors.Is(err, denied) {
		t.Fatalf("card action err = %v; want the AllowKind error", err)
	}
	// A shape error is reported before the permission check.
	asked = nil
	_, err = blocks.ValidateAction(fn, "actions", 0, js(t, `{label: "", target: {title: "t"}}`), opts)
	var be *blocks.Error
	if !errors.As(err, &be) || len(asked) != 0 {
		t.Fatalf("err = %v, asked = %v; want a shape error and no permission check", err, asked)
	}
}

func TestValidateAction_Target(t *testing.T) {
	a, err := blocks.ValidateAction(fn, "actions", 1, js(t, `{label: "Task", target: {title: " Follow up ", intent: " Ask colleague A ", parent: 12}}`), blocks.Options{})
	if err != nil {
		t.Fatal(err)
	}
	if a.Kind != db.InboxActionTarget || a.Primary || a.Target == nil ||
		*a.Target != (db.InboxTargetAction{Title: "Follow up", Intent: "Ask colleague A", Parent: 12}) {
		t.Fatalf("action = %+v %+v", a, a.Target)
	}
	b, _ := json.Marshal(a)
	if string(b) != `{"label":"Task","kind":"target","target":{"title":"Follow up","intent":"Ask colleague A","parent":12}}` {
		t.Fatalf("stored = %s", b)
	}
	for expr, want := range map[string]string{
		`{label: "a", target: {}}`:                                        "actions[0].target.title must be a non-empty string of at most 200 characters",
		`{label: "a", target: {title: 5}}`:                                "actions[0].target.title must be a non-empty string",
		`{label: "a", target: "x"}`:                                       "actions[0].target must be an object {title, intent?, parent?}",
		`{label: "a", target: null}`:                                      "actions[0].target must be an object",
		`{label: "a", target: {title: "t", intent: 5}}`:                   "actions[0].target.intent must be a string",
		`{label: "a", target: {title: "t", parent: 0}}`:                   "actions[0].target.parent must be a target id",
		`{label: "a", target: {title: "t", parent: -1}}`:                  "actions[0].target.parent must be a target id",
		`{label: "a", target: {title: "t", parent: "x"}}`:                 "actions[0].target.parent must be a target id",
		`{label: "a", target: {title: "t", parent: 1.5}}`:                 "actions[0].target.parent must be a target id",
		`{label: "a", target: {title: "t", due: "x"}}`:                    `actions[0].target: unknown field "due"`,
		`{label: "a", target: {title: "t"}, data: {a: 1}}`:                "actions[0]: data is only for a reply action",
		`{label: "a", target: {title: "t"}, open: "https://example.com"}`: "has more than one of open, chat, agent, reply, target",
	} {
		t.Run(expr, func(t *testing.T) {
			_, err := blocks.ValidateAction(fn, "actions", 0, js(t, expr), blocks.Options{})
			var be *blocks.Error
			if !errors.As(err, &be) || !strings.Contains(be.Msg, want) || !strings.HasPrefix(be.Msg, "output.inbox(): ") {
				t.Fatalf("err = %v; want %q", err, want)
			}
		})
	}
}

func TestCanonical_StableAcrossKeyOrder(t *testing.T) {
	a := mustValidate(t, `[{type: "list", title: "t", empty: "e", rows: [{ref: {id: 2, kind: "idea"}, tone: "info", badge: {tone: "danger", text: "b"}, title: "r",
		actions: [{chat: "x", label: "a"}, {target: {parent: 3, intent: "i", title: "t"}, label: "b"}]}]},
		{level: 2, text: "h", type: "heading"}, {type: "person", link: "https://example.com", lines: [{tone: "info", text: "l"}], role: "r", name: "n"}]`)
	b := mustValidate(t, `[{rows: [{title: "r", badge: {text: "b", tone: "danger"}, tone: "info",
		actions: [{label: "a", chat: "x"}, {label: "b", target: {title: "t", intent: "i", parent: 3}}], ref: {kind: "idea", id: 2}}], empty: "e", title: "t", type: "list"},
		{type: "heading", text: "h", level: 2}, {name: "n", role: "r", lines: [{text: "l", tone: "info"}], link: "https://example.com", type: "person"}]`)
	ca, err := a.Canonical()
	if err != nil {
		t.Fatal(err)
	}
	cb, _ := b.Canonical()
	if string(ca) != string(cb) {
		t.Fatalf("canonical differs:\n%s\n%s", ca, cb)
	}
	for range 20 {
		if again, _ := a.Canonical(); string(again) != string(ca) {
			t.Fatal("canonical is not deterministic")
		}
	}
	if blocks.ContentHash("t", "b", &a, "", "", nil) != blocks.ContentHash("t", "b", &b, "", "", nil) {
		t.Fatal("content hash differs across key order")
	}
}

func TestPlainText_ClipsOnARuneBoundary(t *testing.T) {
	d := mustValidate(t, `[{type: "text", markdown: "ééééé"}]`) // 10 bytes
	if got := blocks.PlainText(d, 0); got != "ééééé" {
		t.Fatalf("uncapped = %q", got)
	}
	if got := blocks.PlainText(d, 10); got != "ééééé" {
		t.Fatalf("at the cap = %q", got)
	}
	for limit := 3; limit < 10; limit++ {
		got := blocks.PlainText(d, limit)
		if !utf8.ValidString(got) || len(got) > limit || !strings.HasSuffix(got, "…") {
			t.Fatalf("PlainText(cap %d) = %q (%d bytes); want valid UTF-8 within the cap ending in …", limit, got, len(got))
		}
	}
	if got := blocks.PlainText(d, 7); got != "éé…" {
		t.Fatalf("PlainText(cap 7) = %q; want éé…", got)
	}
}

func TestContentHash_ChangesWithEachField(t *testing.T) {
	d := mustValidate(t, `[{type: "text", markdown: "x"}]`)
	d2 := mustValidate(t, `[{type: "text", markdown: "y"}]`)
	acts := []db.InboxAction{{Label: "a", Kind: db.InboxActionChat, Chat: "x", Primary: true}}
	base := blocks.ContentHash("t", "b", &d, "high", "https://example.com", acts)
	if len(base) != 64 {
		t.Fatalf("hash = %q; want 64 hex characters", base)
	}
	variants := map[string]string{
		"title":    blocks.ContentHash("t2", "b", &d, "high", "https://example.com", acts),
		"body":     blocks.ContentHash("t", "b2", &d, "high", "https://example.com", acts),
		"blocks":   blocks.ContentHash("t", "b", &d2, "high", "https://example.com", acts),
		"no doc":   blocks.ContentHash("t", "b", nil, "high", "https://example.com", acts),
		"priority": blocks.ContentHash("t", "b", &d, "low", "https://example.com", acts),
		"link":     blocks.ContentHash("t", "b", &d, "high", "https://example.com/2", acts),
		"actions":  blocks.ContentHash("t", "b", &d, "high", "https://example.com", nil),
		"action":   blocks.ContentHash("t", "b", &d, "high", "https://example.com", []db.InboxAction{{Label: "a", Kind: db.InboxActionChat, Chat: "y", Primary: true}}),
	}
	for name, h := range variants {
		if h == base {
			t.Errorf("changing %s kept the hash", name)
		}
	}
	// nil and empty actions are the same card.
	if blocks.ContentHash("t", "b", nil, "", "", nil) != blocks.ContentHash("t", "b", nil, "", "", []db.InboxAction{}) {
		t.Error("nil and empty actions hash differently")
	}
	// Reply data built from a Go map (random iteration order) hashes the same.
	for range 20 {
		a, err := blocks.ValidateAction(fn, "actions", 0, map[string]any{"label": "r", "reply": "v",
			"data": map[string]any{"a": int64(1), "b": "x", "c": true, "d": int64(4), "e": "y"}}, blocks.Options{})
		if err != nil {
			t.Fatal(err)
		}
		if got := blocks.ContentHash("t", "b", nil, "", "", []db.InboxAction{a}); got != blocks.ContentHash("t", "b", nil, "", "", []db.InboxAction{{Label: "r", Kind: db.InboxActionReply, Reply: "v", Data: json.RawMessage(`{"a":1,"b":"x","c":true,"d":4,"e":"y"}`), Primary: true}}) {
			t.Fatal("hash depends on map order")
		}
	}
}

func TestActionHash(t *testing.T) {
	a := db.InboxAction{Label: "Task", Kind: db.InboxActionTarget, Target: &db.InboxTargetAction{Title: "t"}}
	h := blocks.ActionHash(a)
	if len(h) != 16 || strings.Trim(h, "0123456789abcdef") != "" {
		t.Fatalf("hash = %q; want 16 lowercase hex characters", h)
	}
	b := a
	b.Target = &db.InboxTargetAction{Title: "t", Parent: 3}
	if blocks.ActionHash(b) == h {
		t.Fatal("a different parent kept the hash")
	}
	if blocks.ActionHash(a) != h {
		t.Fatal("hash is not deterministic")
	}
}

func TestFlattenActions(t *testing.T) {
	if got := blocks.FlattenActions(nil, nil); got == nil || len(got) != 0 {
		t.Fatalf("FlattenActions(nil, nil) = %#v; want empty, not nil", got)
	}
	card := []db.InboxAction{{Label: "C"}}
	got := blocks.FlattenActions(card, nil)
	got[0].Label = "changed"
	if card[0].Label != "C" {
		t.Fatal("FlattenActions aliases the card's slice")
	}
}

func TestDecode(t *testing.T) {
	if d, err := blocks.Decode(""); d != nil || err != nil {
		t.Fatalf(`Decode("") = %v, %v; want nil, nil`, d, err)
	}
	for _, bad := range []string{"{", "[]", `{"blocks":[]}`, `{"v":1,"blocks":[{"text":"x"}]}`, `{"v":1,"blocks":[{"type":"chart"}]}`, `{"v":"1"}`} {
		d, err := blocks.Decode(bad)
		if d != nil || err == nil || errors.Is(err, blocks.ErrUnsupportedVersion) {
			t.Errorf("Decode(%s) = %v, %v; want an unreadable error", bad, d, err)
		}
	}
	d, err := blocks.Decode(`{"v":1}`)
	if err != nil || d.Blocks == nil {
		t.Fatalf("Decode(no blocks) = %+v, %v", d, err)
	}
}

// FuzzValidateCanonical: whatever Validate accepts canonicalises within the
// cap, decodes back, and re-canonicalises to the same bytes.
func FuzzValidateCanonical(f *testing.F) {
	f.Add(`[{type: "heading", text: "h"}]`)
	f.Add(`[{type: "list", rows: [{title: "r", badge: {text: "b", tone: "info"}, actions: [{label: "a", target: {title: "t"}}]}]}]`)
	f.Add(`[{type: "table", columns: [{title: "c", align: "trailing"}], rows: [["x"], [{text: "y", link: "https://example.com"}]]}]`)
	f.Add(`[{type: "person", name: "n", avatar: {slack_user: "acme:U1"}, lines: ["l"]}, {type: "metrics", items: [{label: "l", value: "v"}]}]`)
	f.Add(`[{type: "text", markdown: "<a> &  "}, {type: "link", title: "t", url: "watchtower-nav://home"}]`)
	f.Fuzz(func(t *testing.T, expr string) {
		v, err := goja.New().RunString("(" + expr + ")")
		if err != nil {
			return
		}
		d, err := blocks.Validate(fn, v.Export(), blocks.Options{BuiltIn: true})
		if err != nil {
			var be *blocks.Error
			if !errors.As(err, &be) {
				t.Fatalf("refusal is %T: %v", err, err)
			}
			return
		}
		b, err := d.Canonical()
		if err != nil || len(b) > blocks.MaxBlocksBytes {
			t.Fatalf("Canonical = %d bytes, %v", len(b), err)
		}
		back, err := blocks.Decode(string(b))
		if err != nil {
			t.Fatalf("Decode(%s): %v", b, err)
		}
		again, err := back.Canonical()
		if err != nil || string(again) != string(b) {
			t.Fatalf("round trip:\n%s\n%s", b, again)
		}
		_ = blocks.PlainText(d, 64)
	})
}

// TestContentHash_DefaultPriorityIsMedium: an omitted priority (”) and the
// explicit default "medium" (what the row stores for ”) hash the same, so a
// script that starts spelling out the default does not make a living card
// new again.
func TestContentHash_DefaultPriorityIsMedium(t *testing.T) {
	if blocks.ContentHash("t", "b", nil, "", "", nil) != blocks.ContentHash("t", "b", nil, blocks.DefaultPriority, "", nil) {
		t.Fatal(`ContentHash with priority "" differs from "medium"`)
	}
	if blocks.ContentHash("t", "b", nil, "", "", nil) == blocks.ContentHash("t", "b", nil, "low", "", nil) {
		t.Fatal(`ContentHash with priority "" equals "low"`)
	}
}
