// Package blocks is the Inbox card's block document (Inbox builder A): the
// v1 block set, its validation from a script's value, the canonical JSON
// Go stores and the Desktop and phone decode, the plain text that stands in
// for the card's body, the content and action hashes, and the one action
// grammar shared by card actions and block actions.
//
// The canonical form: keys in the struct order below, every key with a
// default written out (a heading's level, a list's rows and empty text, a
// row's actions, a column's align, a person's lines), optional keys without
// a default left out when absent, table cells and person lines always as
// objects, every block string trimmed (an action keeps its label, chat,
// agent task and reply value as written; only a target's title and intent
// are trimmed), encoded by marshal (below), and a reply action's data as
// the opaque bytes the action grammar stored. It is pinned by
// testdata/blocks_cases.json.
//
// The package is a leaf: it imports db for the action type only and never
// automations; the SDK passes its permission checks in through Options.
package blocks

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"

	"watchtower/internal/db"
)

// Version is the only document version Go writes.
const Version = 1

// Block types.
const (
	TypeHeading = "heading"
	TypeText    = "text"
	TypeList    = "list"
	TypeTable   = "table"
	TypePerson  = "person"
	TypeMetrics = "metrics"
	TypeLink    = "link"
	TypeActions = "actions"
)

// blockTypes is every v1 block type, in the order error messages list them.
var blockTypes = []string{TypeHeading, TypeText, TypeList, TypeTable, TypePerson, TypeMetrics, TypeLink, TypeActions}

// Tones are the six colour names a block may use.
var Tones = []string{"neutral", "info", "success", "warning", "danger", "accent"}

// Ref kinds of a list row; RefAction, RefReminder, RefMailSender and
// RefWaitingOlder only from a built-in automation. RefMailSender and
// RefWaitingOlder carry a text id (Ref.Key), the others an integer one.
const (
	RefInboxItem    = "inbox_item"
	RefTrack        = "track"
	RefIdea         = "idea"
	RefReminder     = "reminder"
	RefAction       = "action"
	RefMailSender   = "mail_sender"
	RefWaitingOlder = "waiting_older"
)

var refKinds = []string{RefInboxItem, RefTrack, RefIdea, RefReminder, RefAction, RefMailSender, RefWaitingOlder}

// textRefKind reports whether a ref of kind carries a text id.
func textRefKind(kind string) bool { return kind == RefMailSender || kind == RefWaitingOlder }

// Error is a validation refusal; Msg is the whole message the script sees
// (the SDK throws it as a ValidationError).
type Error struct{ Msg string }

func (e *Error) Error() string { return e.Msg }

func errorf(format string, a ...any) error { return &Error{Msg: fmt.Sprintf(format, a...)} }

// Document is a card's block document.
type Document struct {
	V      int     `json:"v"`
	Blocks []Block `json:"blocks"`
}

// Block is one block: Type names the one non-nil kind field.
type Block struct {
	Type    string
	Heading *Heading
	Text    *Text
	List    *List
	Table   *Table
	Person  *Person
	Metrics *Metrics
	Link    *Link
	Actions *ActionsBlock
}

// Heading is a heading block.
type Heading struct {
	Text  string `json:"text"`
	Level int    `json:"level"`
}

// Text is a markdown text block.
type Text struct {
	Markdown string `json:"markdown"`
}

// List is a list block.
type List struct {
	Title string    `json:"title,omitempty"`
	Rows  []ListRow `json:"rows"`
	Empty string    `json:"empty"`
}

// ListRow is one row of a list.
type ListRow struct {
	Title    string           `json:"title"`
	Subtitle string           `json:"subtitle,omitempty"`
	Badge    *Badge           `json:"badge,omitempty"`
	Tone     string           `json:"tone,omitempty"`
	Link     string           `json:"link,omitempty"`
	Actions  []db.InboxAction `json:"actions"`
	Ref      *Ref             `json:"ref,omitempty"`
}

// Badge is a row's badge.
type Badge struct {
	Text string `json:"text"`
	Tone string `json:"tone,omitempty"`
}

// Ref points a row at a record sub-project B draws native actions for.
// Its JSON id is Key (a string) for a text kind (mail_sender,
// waiting_older) and ID (an integer) for every other kind, so an integer
// ref's canonical bytes are what they were before text ids existed.
type Ref struct {
	Kind string `json:"kind"`
	ID   int64  `json:"id"`
	Key  string `json:"-"` // written as "id" (MarshalJSON)
}

// MarshalJSON writes {"kind": …, "id": …}, id a string for a text kind.
func (r Ref) MarshalJSON() ([]byte, error) {
	if textRefKind(r.Kind) {
		return marshal(struct {
			Kind string `json:"kind"`
			ID   string `json:"id"`
		}{r.Kind, r.Key})
	}
	return marshal(struct {
		Kind string `json:"kind"`
		ID   int64  `json:"id"`
	}{r.Kind, r.ID})
}

// UnmarshalJSON reads a ref; a text kind's id must be a string and every
// other kind's a number.
func (r *Ref) UnmarshalJSON(data []byte) error {
	var raw struct {
		Kind string          `json:"kind"`
		ID   json.RawMessage `json:"id"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	*r = Ref{Kind: raw.Kind}
	if textRefKind(raw.Kind) {
		if len(raw.ID) == 0 || raw.ID[0] != '"' {
			return fmt.Errorf("a %s ref's id is not a string", raw.Kind)
		}
		return json.Unmarshal(raw.ID, &r.Key)
	}
	if len(raw.ID) == 0 || raw.ID[0] == '"' {
		return fmt.Errorf("a %s ref's id is not a number", raw.Kind)
	}
	return json.Unmarshal(raw.ID, &r.ID)
}

// Table is a table block; every row has exactly len(Columns) cells.
type Table struct {
	Title   string   `json:"title,omitempty"`
	Columns []Column `json:"columns"`
	Rows    [][]Cell `json:"rows"`
}

// Column is a table column.
type Column struct {
	Title string `json:"title"`
	Align string `json:"align"`
}

// Cell is a table cell.
type Cell struct {
	Text string `json:"text"`
	Tone string `json:"tone,omitempty"`
	Link string `json:"link,omitempty"`
}

// Person is a person block.
type Person struct {
	Name   string       `json:"name"`
	Role   string       `json:"role,omitempty"`
	Avatar *Avatar      `json:"avatar,omitempty"`
	Lines  []PersonLine `json:"lines"`
	Link   string       `json:"link,omitempty"`
}

// Avatar names the local Slack user whose picture a person block shows.
type Avatar struct {
	SlackUser string `json:"slack_user"`
}

// PersonLine is one line under a person.
type PersonLine struct {
	Text string `json:"text"`
	Tone string `json:"tone,omitempty"`
}

// Metrics is a row of figures.
type Metrics struct {
	Items []Metric `json:"items"`
}

// Metric is one figure.
type Metric struct {
	Label string `json:"label"`
	Value string `json:"value"`
	Tone  string `json:"tone,omitempty"`
	Hint  string `json:"hint,omitempty"`
}

// Link is a tappable link row.
type Link struct {
	Title    string `json:"title"`
	URL      string `json:"url"`
	Subtitle string `json:"subtitle,omitempty"`
}

// ActionsBlock is a button row inside the body.
type ActionsBlock struct {
	Actions []db.InboxAction `json:"actions"`
}

// payload returns the block's kind struct.
func (b Block) payload() (any, error) {
	var p any
	switch b.Type {
	case TypeHeading:
		p = b.Heading
	case TypeText:
		p = b.Text
	case TypeList:
		p = b.List
	case TypeTable:
		p = b.Table
	case TypePerson:
		p = b.Person
	case TypeMetrics:
		p = b.Metrics
	case TypeLink:
		p = b.Link
	case TypeActions:
		p = b.Actions
	default:
		return nil, fmt.Errorf("unknown block type %q", b.Type)
	}
	return p, nil
}

// MarshalJSON writes {"type": …} followed by the kind's fields.
func (b Block) MarshalJSON() ([]byte, error) {
	p, err := b.payload()
	if err != nil {
		return nil, err
	}
	body, err := marshal(p)
	if err != nil {
		return nil, err
	}
	if len(body) < 2 || body[0] != '{' {
		return nil, fmt.Errorf("block %q has no fields", b.Type)
	}
	typ, err := marshal(b.Type)
	if err != nil {
		return nil, err
	}
	out := append([]byte(`{"type":`), typ...)
	if len(body) > 2 {
		out = append(out, ',')
	}
	return append(out, body[1:]...), nil
}

// UnmarshalJSON reads a block by its type.
func (b *Block) UnmarshalJSON(data []byte) error {
	var head struct {
		Type *string `json:"type"`
	}
	if err := json.Unmarshal(data, &head); err != nil {
		return err
	}
	if head.Type == nil {
		return errors.New("a block has no type")
	}
	*b = Block{Type: *head.Type}
	var p any
	switch b.Type {
	case TypeHeading:
		b.Heading = &Heading{}
		p = b.Heading
	case TypeText:
		b.Text = &Text{}
		p = b.Text
	case TypeList:
		b.List = &List{}
		p = b.List
	case TypeTable:
		b.Table = &Table{}
		p = b.Table
	case TypePerson:
		b.Person = &Person{}
		p = b.Person
	case TypeMetrics:
		b.Metrics = &Metrics{}
		p = b.Metrics
	case TypeLink:
		b.Link = &Link{}
		p = b.Link
	case TypeActions:
		b.Actions = &ActionsBlock{}
		p = b.Actions
	default:
		return fmt.Errorf("unknown block type %q", b.Type)
	}
	return json.Unmarshal(data, p)
}

// marshal is encoding/json without HTML escaping and without the trailing
// newline: <, > and & stay raw, while control characters are written as
// \u00XX (\n, \r, \t as such), U+2028/U+2029 as \u2028/\u2029, and
// "/" unescaped. A raw value inside (an action's data) is copied as stored.
// Every reader that rebuilds these bytes (the Swift action hash) follows
// this rule; the shared fixture pins it.
func marshal(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

// Canonical is the document's stored form.
func (d Document) Canonical() ([]byte, error) {
	if d.Blocks == nil {
		d.Blocks = []Block{}
	}
	return marshal(d)
}

// ErrUnsupportedVersion is Decode's refusal of a document newer than v1.
var ErrUnsupportedVersion = errors.New("unsupported block document version")

// Decode reads a stored document; "" (no blocks) is nil, nil. A version
// other than 1 is ErrUnsupportedVersion; any other undecodable document is
// an error, never nil.
func Decode(stored string) (*Document, error) {
	if stored == "" {
		return nil, nil
	}
	var head struct {
		V *int `json:"v"`
	}
	if err := json.Unmarshal([]byte(stored), &head); err != nil {
		return nil, fmt.Errorf("decoding blocks: %w", err)
	}
	if head.V == nil {
		return nil, errors.New("decoding blocks: no version")
	}
	if *head.V != Version {
		return nil, fmt.Errorf("decoding blocks: version %d: %w", *head.V, ErrUnsupportedVersion)
	}
	var d Document
	if err := json.Unmarshal([]byte(stored), &d); err != nil {
		return nil, fmt.Errorf("decoding blocks: %w", err)
	}
	if d.Blocks == nil {
		d.Blocks = []Block{}
	}
	return &d, nil
}
