package blocks_test

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"os"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/dop251/goja"

	"watchtower/internal/automations/blocks"
	"watchtower/internal/db"
)

// The shared fixture of Inbox builder A (spec, Test strategy): Go is its
// only writer; the Swift decoder reads it (plan Task 13). -update rewrites
// the computed fields of the valid cases (card_actions, canonical,
// plain_text, actions, action_hashes, content_hash); inputs and the invalid cases' messages are
// written by hand.
var update = flag.Bool("update", false, "rewrite the computed fields of testdata/blocks_cases.json")

const fixturePath = "testdata/blocks_cases.json"

// plainTextCap is the SDK's MaxOutputBodyBytes, the cap the body takes.
const plainTextCap = 64 * 1024

type fixture struct {
	Valid       []validCase       `json:"valid"`
	Invalid     []invalidCase     `json:"invalid"`
	Unsupported []unsupportedCase `json:"unsupported"`
}

type validCase struct {
	Name         string          `json:"name"`
	BuiltIn      bool            `json:"built_in"`
	Input        json.RawMessage `json:"input"`
	CardActions  string          `json:"card_actions"`
	Canonical    string          `json:"canonical"`
	PlainText    string          `json:"plain_text"`
	Actions      []string        `json:"actions"`
	ActionHashes []string        `json:"action_hashes"`
	ContentHash  string          `json:"content_hash"`
}

type invalidCase struct {
	Name    string          `json:"name"`
	BuiltIn bool            `json:"built_in"`
	Input   json.RawMessage `json:"input"`
	Error   string          `json:"error"`
}

type unsupportedCase struct {
	Name     string          `json:"name"`
	Document json.RawMessage `json:"document"`
	Version  int             `json:"version"`
}

func readFixture(t *testing.T) fixture {
	t.Helper()
	b, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatal(err)
	}
	var f fixture
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatalf("decoding %s: %v", fixturePath, err)
	}
	return f
}

// exported evaluates a JSON input as the script would pass it and returns
// goja's exported value, exactly what output.inbox hands to the package.
func exported(t *testing.T, input json.RawMessage) map[string]any {
	t.Helper()
	v, err := goja.New().RunString("(" + string(input) + ")")
	if err != nil {
		t.Fatalf("evaluating input: %v", err)
	}
	m, ok := v.Export().(map[string]any)
	if !ok {
		t.Fatalf("input is %T; want an object", v.Export())
	}
	return m
}

// cardResult is what the SDK derives from one output.inbox argument.
type cardResult struct {
	doc       blocks.Document
	stored    []byte // the card's own actions as automation_outputs.actions_json holds them
	canonical []byte
	plain     string
	flat      []db.InboxAction
	hash      string
}

// card runs the card's own actions and its blocks through the package as
// the SDK does (plan Task 5).
func card(input map[string]any, builtIn bool) (cardResult, error) {
	const fn = "output.inbox"
	opts := blocks.Options{BuiltIn: builtIn}
	var actions []db.InboxAction
	if raw, has := input["actions"]; has {
		for i, v := range raw.([]any) {
			a, err := blocks.ValidateAction(fn, "actions", i, v, opts)
			if err != nil {
				return cardResult{}, err
			}
			actions = append(actions, a)
		}
	}
	opts.CardActions = len(actions)
	// db.FinishAutomationRun (commitRunTx) writes actions_json as json.Marshal of the
	// card's actions, [] when there are none (HTML-escaped, unlike the
	// canonical document): the Swift parity test decodes these bytes.
	if actions == nil {
		actions = []db.InboxAction{}
	}
	stored, err := json.Marshal(actions)
	if err != nil {
		return cardResult{}, err
	}
	doc, err := blocks.Validate(fn, input["blocks"], opts)
	if err != nil {
		return cardResult{}, err
	}
	canonical, err := doc.Canonical()
	if err != nil {
		return cardResult{}, err
	}
	title, _ := input["title"].(string)
	priority, _ := input["priority"].(string)
	link, _ := input["link"].(string)
	plain := blocks.PlainText(doc, plainTextCap)
	return cardResult{
		doc:       doc,
		stored:    stored,
		canonical: canonical,
		plain:     plain,
		flat:      blocks.FlattenActions(actions, &doc),
		hash:      blocks.ContentHash(title, plain, &doc, priority, link, actions),
	}, nil
}

func TestFixture_Valid(t *testing.T) {
	f := readFixture(t)
	if len(f.Valid) == 0 {
		t.Fatal("no valid cases")
	}
	for i := range f.Valid {
		c := &f.Valid[i]
		t.Run(c.Name, func(t *testing.T) {
			r, err := card(exported(t, c.Input), c.BuiltIn)
			if err != nil {
				t.Fatalf("refused: %v", err)
			}
			labels, hashes := []string{}, []string{}
			for _, a := range r.flat {
				labels = append(labels, a.Label)
				hashes = append(hashes, blocks.ActionHash(a))
			}
			if *update {
				c.CardActions, c.Canonical, c.PlainText, c.Actions, c.ActionHashes, c.ContentHash =
					string(r.stored), string(r.canonical), r.plain, labels, hashes, r.hash
				return
			}
			if string(r.stored) != c.CardActions {
				t.Errorf("card actions =\n%s\nwant\n%s", r.stored, c.CardActions)
			}
			if string(r.canonical) != c.Canonical {
				t.Errorf("canonical =\n%s\nwant\n%s", r.canonical, c.Canonical)
			}
			if r.plain != c.PlainText {
				t.Errorf("plain text =\n%q\nwant\n%q", r.plain, c.PlainText)
			}
			if !slices.Equal(labels, c.Actions) || !slices.Equal(hashes, c.ActionHashes) {
				t.Errorf("actions = %v %v; want %v %v", labels, hashes, c.Actions, c.ActionHashes)
			}
			if r.hash != c.ContentHash {
				t.Errorf("content hash = %s; want %s", r.hash, c.ContentHash)
			}
			// The canonical document decodes and canonicalises to itself.
			d, err := blocks.Decode(c.Canonical)
			if err != nil || d == nil {
				t.Fatalf("Decode(canonical) = %v, %v", d, err)
			}
			again, err := d.Canonical()
			if err != nil || string(again) != c.Canonical {
				t.Errorf("re-canonical = %s, %v; want the stored bytes", again, err)
			}
			if got := blocks.FlattenActions(nil, d); len(got) != len(r.flat)-countCardActions(t, c.Input) {
				t.Errorf("decoded document flattens to %d block actions", len(got))
			}
		})
	}
	if *update {
		writeFixture(t, f)
	}
}

func countCardActions(t *testing.T, input json.RawMessage) int {
	t.Helper()
	a, _ := exported(t, input)["actions"].([]any)
	return len(a)
}

func TestFixture_Invalid(t *testing.T) {
	f := readFixture(t)
	if len(f.Invalid) == 0 {
		t.Fatal("no invalid cases")
	}
	for _, c := range f.Invalid {
		t.Run(c.Name, func(t *testing.T) {
			_, err := card(exported(t, c.Input), c.BuiltIn)
			var be *blocks.Error
			if !errors.As(err, &be) {
				t.Fatalf("err = %v (%T); want a *blocks.Error", err, err)
			}
			if be.Msg != c.Error {
				t.Fatalf("message =\n%s\nwant\n%s", be.Msg, c.Error)
			}
		})
	}
}

func TestFixture_Unsupported(t *testing.T) {
	f := readFixture(t)
	if len(f.Unsupported) == 0 {
		t.Fatal("no unsupported cases")
	}
	for _, c := range f.Unsupported {
		t.Run(c.Name, func(t *testing.T) {
			d, err := blocks.Decode(string(c.Document))
			if d != nil || !errors.Is(err, blocks.ErrUnsupportedVersion) {
				t.Fatalf("Decode = %v, %v; want ErrUnsupportedVersion", d, err)
			}
			if !strings.Contains(err.Error(), "version "+strconv.Itoa(c.Version)) {
				t.Fatalf("err = %v; want it to name version %d", err, c.Version)
			}
		})
	}
}

// TestFixture_CoversEveryField: every block type and every field of the
// document and of an action (reflected from the Go types, so a new field
// without a case fails here) appears in at least one valid canonical
// document.
func TestFixture_CoversEveryField(t *testing.T) {
	f := readFixture(t)
	seen := map[string]bool{}
	for _, c := range f.Valid {
		var v any
		if err := json.Unmarshal([]byte(c.Canonical), &v); err != nil {
			t.Fatalf("%s: canonical: %v", c.Name, err)
		}
		for _, b := range v.(map[string]any)["blocks"].([]any) {
			bm := b.(map[string]any)
			walk(bm["type"].(string), bm, seen)
		}
	}
	for typ, want := range allPaths() {
		for _, p := range want {
			if !seen[typ+"."+p] {
				t.Errorf("no valid case has %s.%s", typ, p)
			}
		}
	}
}

// walk records every key path under prefix ("list.rows.badge.tone"); an
// action's fields are recorded under "action." wherever the action sits.
func walk(prefix string, v any, seen map[string]bool) {
	switch x := v.(type) {
	case map[string]any:
		for k, child := range x {
			p := prefix + "." + k
			seen[p] = true
			if k == "actions" {
				walk("action", child, seen)
				continue
			}
			walk(p, child, seen)
		}
	case []any:
		for _, child := range x {
			walk(prefix, child, seen)
		}
	}
}

// allPaths reflects every JSON key path of each block type's struct.
func allPaths() map[string][]string {
	kinds := map[string]any{
		blocks.TypeHeading: blocks.Heading{}, blocks.TypeText: blocks.Text{}, blocks.TypeList: blocks.List{},
		blocks.TypeTable: blocks.Table{}, blocks.TypePerson: blocks.Person{}, blocks.TypeMetrics: blocks.Metrics{},
		blocks.TypeLink: blocks.Link{}, blocks.TypeActions: blocks.ActionsBlock{},
	}
	out := map[string][]string{"action": typePaths("", reflect.TypeOf(db.InboxAction{}))}
	for typ, v := range kinds {
		out[typ] = typePaths("", reflect.TypeOf(v))
	}
	return out
}

var actionType = reflect.TypeOf(db.InboxAction{})

func typePaths(prefix string, t reflect.Type) []string {
	for t.Kind() == reflect.Pointer || t.Kind() == reflect.Slice {
		t = t.Elem()
	}
	if t.Kind() != reflect.Struct {
		return nil
	}
	var out []string
	for i := range t.NumField() {
		name, _, _ := strings.Cut(t.Field(i).Tag.Get("json"), ",")
		if name == "" || name == "-" {
			continue
		}
		p := name
		if prefix != "" {
			p = prefix + "." + name
		}
		out = append(out, p)
		ft := t.Field(i).Type
		if ft != reflect.TypeOf(json.RawMessage{}) && (ft.Kind() != reflect.Slice || ft.Elem() != actionType) {
			out = append(out, typePaths(p, t.Field(i).Type)...)
		}
	}
	return out
}

func writeFixture(t *testing.T, f fixture) {
	t.Helper()
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(f); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fixturePath, buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}
