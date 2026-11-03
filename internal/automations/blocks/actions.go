package blocks

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"maps"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"

	"watchtower/internal/db"
)

// The action grammar (panel and Inbox spec B2, Inbox builder A): one kind
// per action — Link {open}, Chat {chat}, Agent {agent: {task, workbench?}},
// Reply {reply, data?} or Target {target: {title, intent?, parent?}}. The
// first action of a list is primary unless it sets primary: false.

// cardURLSchemes are the schemes a card URL may use; the Desktop checks a
// link again when it is pressed.
var cardURLSchemes = []string{"http", "https", "watchtower-nav"}

// actionKindKeys maps each action kind's key to its db kind.
var actionKindKeys = []struct{ key, kind string }{
	{"open", db.InboxActionLink},
	{"chat", db.InboxActionChat},
	{"agent", db.InboxActionAgent},
	{"reply", db.InboxActionReply},
	{"target", db.InboxActionTarget},
}

var actionKeys = []string{"label", "primary", "open", "chat", "agent", "reply", "target", "data"}

// Options are the caller's rules for Validate and ValidateAction.
type Options struct {
	// BuiltIn admits action and reminder refs (built-in automations only).
	BuiltIn bool
	// AllowKind is the caller's permission check for an action of a db kind
	// (the SDK: reply needs inbox:reply, target needs outputs: [target]);
	// its error is returned unchanged. Nil admits every kind.
	AllowKind func(kind string) error
	// CardActions is the number of the card's own actions, counted with the
	// block actions against MaxActions.
	CardActions int
}

// ValidateAction validates field[i], one action of fn's call; the first
// action of its list (i == 0) is primary unless it sets primary: false.
func ValidateAction(fn, field string, i int, v any, opts Options) (db.InboxAction, error) {
	a, err := validateActionShape(fn, actionField(field, i), i, v)
	if err != nil {
		return a, err
	}
	if opts.AllowKind != nil {
		if err := opts.AllowKind(a.Kind); err != nil {
			return a, err
		}
	}
	return a, nil
}

func actionField(field string, i int) string {
	return field + "[" + strconv.Itoa(i) + "]"
}

func validateActionShape(fn, field string, i int, v any) (db.InboxAction, error) {
	fields, ok := v.(map[string]any)
	if !ok {
		return db.InboxAction{}, errorf("%s(): %s must be an object {label, open|chat|agent|reply|target}", fn, field)
	}
	for _, k := range slices.Sorted(maps.Keys(fields)) {
		if !slices.Contains(actionKeys, k) {
			return db.InboxAction{}, errorf("%s(): %s: unknown field %q", fn, field, k)
		}
	}
	a := db.InboxAction{Primary: i == 0}
	if a.Label, ok = fields["label"].(string); !ok || strings.TrimSpace(a.Label) == "" {
		return a, errorf("%s(): %s.label must be a non-empty string", fn, field)
	}
	if n := utf8.RuneCountInString(a.Label); n > MaxActionLabelChars {
		return a, errorf("%s(): %s.label is %d characters; the limit is %d", fn, field, n, MaxActionLabelChars)
	}
	if p, has := fields["primary"]; has {
		b, isBool := p.(bool)
		switch {
		case i != 0 || (isBool && b):
			return a, errorf("%s(): %s: primary may only be set to false on the first action", fn, field)
		case !isBool:
			return a, errorf("%s(): %s.primary must be false", fn, field)
		}
		a.Primary = false
	}
	for _, k := range actionKindKeys {
		if _, has := fields[k.key]; !has {
			continue
		}
		if a.Kind != "" {
			return a, errorf("%s(): %s has more than one of open, chat, agent, reply, target", fn, field)
		}
		a.Kind = k.kind
	}
	if _, has := fields["data"]; has && a.Kind != db.InboxActionReply {
		return a, errorf("%s(): %s: data is only for a reply action", fn, field)
	}
	var err error
	switch a.Kind {
	case db.InboxActionLink:
		s, isString := fields["open"].(string)
		if !isString {
			return a, errorf("%s(): %s.open must be a string", fn, field)
		}
		a.Open, err = CheckURL(fn, field+".open", s)
	case db.InboxActionChat:
		a.Chat, err = actionText(fn, field+".chat", fields["chat"])
	case db.InboxActionAgent:
		a.Agent, err = agentAction(fn, field+".agent", fields["agent"])
	case db.InboxActionReply:
		err = replyAction(fn, field, fields, &a)
	case db.InboxActionTarget:
		a.Target, err = targetAction(fn, field+".target", fields["target"])
	default:
		return a, errorf("%s(): %s needs one of open, chat, agent, reply, target", fn, field)
	}
	return a, err
}

// actionText is a chat's first message or an agent's task: a non-empty
// string of at most MaxActionTextBytes.
func actionText(fn, field string, v any) (string, error) {
	s, ok := v.(string)
	if !ok || strings.TrimSpace(s) == "" {
		return "", errorf("%s(): %s must be a non-empty string", fn, field)
	}
	if len(s) > MaxActionTextBytes {
		return "", errorf("%s(): %s is %d bytes; the limit is %d", fn, field, len(s), MaxActionTextBytes)
	}
	return s, nil
}

// agentAction validates {task, workbench?}; a workbench is a positive id or
// a non-empty name.
func agentAction(fn, field string, v any) (*db.InboxAgentAction, error) {
	fields, ok := v.(map[string]any)
	if !ok {
		return nil, errorf("%s(): %s must be an object {task, workbench?}", fn, field)
	}
	for _, k := range slices.Sorted(maps.Keys(fields)) {
		if k != "task" && k != "workbench" {
			return nil, errorf("%s(): %s: unknown field %q", fn, field, k)
		}
	}
	task, err := actionText(fn, field+".task", fields["task"])
	if err != nil {
		return nil, err
	}
	a := &db.InboxAgentAction{Task: task}
	w, has := fields["workbench"]
	if !has {
		return a, nil
	}
	switch x := w.(type) {
	case int64:
		if x > 0 {
			a.Workbench, err = json.Marshal(x)
			return a, err
		}
	case string:
		if strings.TrimSpace(x) != "" {
			a.Workbench, err = json.Marshal(x)
			return a, err
		}
	}
	return nil, errorf("%s(): %s.workbench must be a workbench id or name", fn, field)
}

// replyAction validates a reply's value and its optional data object.
func replyAction(fn, field string, fields map[string]any, a *db.InboxAction) error {
	s, ok := fields["reply"].(string)
	if !ok || strings.TrimSpace(s) == "" {
		return errorf("%s(): %s.reply must be a non-empty string", fn, field)
	}
	if n := utf8.RuneCountInString(s); n > MaxReplyValueChars {
		return errorf("%s(): %s.reply is %d characters; the limit is %d", fn, field, n, MaxReplyValueChars)
	}
	a.Reply = s
	d, has := fields["data"]
	if !has {
		return nil
	}
	if _, isObject := d.(map[string]any); !isObject {
		return errorf("%s(): %s.data must be an object", fn, field)
	}
	b, err := json.Marshal(d)
	if err != nil {
		return errorf("%s(): %s.data: %v", fn, field, err)
	}
	if len(b) > MaxActionDataBytes {
		return errorf("%s(): %s.data is %d bytes of JSON; the limit is %d", fn, field, len(b), MaxActionDataBytes)
	}
	a.Data = b
	return nil
}

// targetAction validates {title, intent?, parent?}: the task a press
// proposes. Nothing is checked against the database here; the parent is
// checked at propose and at apply.
func targetAction(fn, field string, v any) (*db.InboxTargetAction, error) {
	fields, ok := v.(map[string]any)
	if !ok {
		return nil, errorf("%s(): %s must be an object {title, intent?, parent?}", fn, field)
	}
	for _, k := range slices.Sorted(maps.Keys(fields)) {
		if k != "title" && k != "intent" && k != "parent" {
			return nil, errorf("%s(): %s: unknown field %q", fn, field, k)
		}
	}
	t := &db.InboxTargetAction{}
	title, ok := fields["title"].(string)
	t.Title = strings.TrimSpace(title)
	if !ok || t.Title == "" || utf8.RuneCountInString(t.Title) > MaxTargetTitleChars {
		return nil, errorf("%s(): %s.title must be a non-empty string of at most %d characters", fn, field, MaxTargetTitleChars)
	}
	if raw, has := fields["intent"]; has {
		s, isString := raw.(string)
		if !isString {
			return nil, errorf("%s(): %s.intent must be a string", fn, field)
		}
		t.Intent = strings.TrimSpace(s)
		if n := utf8.RuneCountInString(t.Intent); n > MaxTargetIntentChars {
			return nil, errorf("%s(): %s.intent is %d characters; the limit is %d", fn, field, n, MaxTargetIntentChars)
		}
	}
	if raw, has := fields["parent"]; has {
		id, isInt := raw.(int64)
		if !isInt || id <= 0 {
			return nil, errorf("%s(): %s.parent must be a target id", fn, field)
		}
		t.Parent = id
	}
	return t, nil
}

// CheckURL admits a card URL: an http, https or watchtower-nav URL (the
// scheme in any case) with a host, at most MaxLinkBytes long.
func CheckURL(fn, field, raw string) (string, error) {
	if len(raw) > MaxLinkBytes {
		return "", errorf("%s(): %s is %d bytes; the limit is %d", fn, field, len(raw), MaxLinkBytes)
	}
	u, err := url.Parse(raw)
	if err != nil || !slices.Contains(cardURLSchemes, strings.ToLower(u.Scheme)) || u.Host == "" {
		return "", errorf("%s(): %s must be an http, https or watchtower-nav:// link with a host", fn, field)
	}
	return raw, nil
}

// ActionHash is the first 16 hex characters of the SHA-256 of the action's
// canonical JSON: the button's identity in a target proposal's context.
func ActionHash(a db.InboxAction) string {
	b, err := marshal(a)
	if err != nil {
		// A validated action always marshals; an unmarshalable one (raw
		// data that is not JSON) still gets a stable, distinct hash.
		b = []byte("unmarshalable:" + err.Error())
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])[:16]
}

// FlattenActions is the card's press order: the card's own actions, then
// each block action in document order (a list's row actions in row order,
// an actions block's actions in order). Never nil.
func FlattenActions(card []db.InboxAction, doc *Document) []db.InboxAction {
	out := append([]db.InboxAction{}, card...)
	if doc == nil {
		return out
	}
	for _, b := range doc.Blocks {
		switch {
		case b.List != nil:
			for _, r := range b.List.Rows {
				out = append(out, r.Actions...)
			}
		case b.Actions != nil:
			out = append(out, b.Actions.Actions...)
		}
	}
	return out
}
