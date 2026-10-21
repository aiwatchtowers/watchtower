package automations

import (
	"encoding/json"
	"fmt"
	"net/url"
	"slices"
	"strings"
	"unicode/utf8"

	"watchtower/internal/db"
)

// An Inbox card's own fields (panel and Inbox spec B2): output.inbox takes
// an optional source link and up to MaxInboxActions buttons, each of exactly
// one kind — Link {open}, Chat {chat}, Agent {agent: {task, workbench?}} or
// Reply {reply, data?}. The first action is primary unless it sets
// primary: false.

// cardURLSchemes are the schemes a card link may use; the Desktop checks a
// link again when it is pressed.
var cardURLSchemes = []string{"http", "https", "watchtower-nav"}

// actionKindKeys maps each action kind's key to its db kind.
var actionKindKeys = []struct{ key, kind string }{
	{"open", db.InboxActionLink},
	{"chat", db.InboxActionChat},
	{"agent", db.InboxActionAgent},
	{"reply", db.InboxActionReply},
}

var actionKeys = []string{"label", "primary", "open", "chat", "agent", "reply", "data"}

// inboxCard validates output.inbox's link and actions. A Reply action needs
// inbox:reply: without it the call is a PermissionDenied. Actions is never
// nil.
func inboxCard(env *Env, fn string, fields map[string]any) (link string, actions []db.InboxAction, err error) {
	if raw, has := fields["link"]; has {
		s, ok := raw.(string)
		if !ok {
			return "", nil, validationf("%s(): link must be a string", fn)
		}
		if link, err = checkCardURL(fn, "link", s); err != nil {
			return "", nil, err
		}
	}
	actions = []db.InboxAction{}
	raw, has := fields["actions"]
	if !has {
		return link, actions, nil
	}
	list, ok := raw.([]any)
	if !ok {
		return "", nil, validationf("%s(): actions must be an array", fn)
	}
	if len(list) > MaxInboxActions {
		return "", nil, validationf("%s(): %d actions; a card takes at most %d", fn, len(list), MaxInboxActions)
	}
	for i, v := range list {
		a, err := inboxAction(fn, i, v)
		if err != nil {
			return "", nil, err
		}
		if a.Kind == db.InboxActionReply {
			m, err := manifestOf(env)
			if err != nil {
				return "", nil, err
			}
			if _, err := m.AllowInboxReply(); err != nil {
				return "", nil, err
			}
		}
		actions = append(actions, a)
	}
	return link, actions, nil
}

// inboxAction validates actions[i].
func inboxAction(fn string, i int, v any) (db.InboxAction, error) {
	field := fmt.Sprintf("actions[%d]", i)
	fields, ok := v.(map[string]any)
	if !ok {
		return db.InboxAction{}, validationf("%s(): %s must be an object {label, open|chat|agent|reply}", fn, field)
	}
	for k := range fields {
		if !slices.Contains(actionKeys, k) {
			return db.InboxAction{}, validationf("%s(): %s: unknown field %q", fn, field, k)
		}
	}
	a := db.InboxAction{Primary: i == 0}
	if a.Label, ok = fields["label"].(string); !ok || a.Label == "" {
		return a, validationf("%s(): %s.label must be a non-empty string", fn, field)
	}
	if n := utf8.RuneCountInString(a.Label); n > MaxInboxActionLabelChars {
		return a, validationf("%s(): %s.label is %d characters; the limit is %d", fn, field, n, MaxInboxActionLabelChars)
	}
	if p, has := fields["primary"]; has {
		b, isBool := p.(bool)
		switch {
		case i != 0 || (isBool && b):
			return a, validationf("%s(): %s: primary may only be set to false on the first action", fn, field)
		case !isBool:
			return a, validationf("%s(): %s.primary must be false", fn, field)
		}
		a.Primary = false
	}
	for _, k := range actionKindKeys {
		if _, has := fields[k.key]; !has {
			continue
		}
		if a.Kind != "" {
			return a, validationf("%s(): %s has more than one of open, chat, agent, reply", fn, field)
		}
		a.Kind = k.kind
	}
	if _, has := fields["data"]; has && a.Kind != db.InboxActionReply {
		return a, validationf("%s(): %s: data is only for a reply action", fn, field)
	}
	var err error
	switch a.Kind {
	case db.InboxActionLink:
		s, isString := fields["open"].(string)
		if !isString {
			return a, validationf("%s(): %s.open must be a string", fn, field)
		}
		a.Open, err = checkCardURL(fn, field+".open", s)
	case db.InboxActionChat:
		a.Chat, err = actionText(fn, field+".chat", fields["chat"])
	case db.InboxActionAgent:
		a.Agent, err = agentAction(fn, field+".agent", fields["agent"])
	case db.InboxActionReply:
		err = replyAction(fn, field, fields, &a)
	default:
		return a, validationf("%s(): %s needs one of open, chat, agent, reply", fn, field)
	}
	return a, err
}

// actionText is a chat's first message or an agent's task: a non-empty
// string of at most MaxInboxActionTextBytes.
func actionText(fn, field string, v any) (string, error) {
	s, ok := v.(string)
	if !ok || strings.TrimSpace(s) == "" {
		return "", validationf("%s(): %s must be a non-empty string", fn, field)
	}
	if len(s) > MaxInboxActionTextBytes {
		return "", validationf("%s(): %s is %d bytes; the limit is %d", fn, field, len(s), MaxInboxActionTextBytes)
	}
	return s, nil
}

// agentAction validates {task, workbench?}; a workbench is a positive id or
// a non-empty name.
func agentAction(fn, field string, v any) (*db.InboxAgentAction, error) {
	fields, ok := v.(map[string]any)
	if !ok {
		return nil, validationf("%s(): %s must be an object {task, workbench?}", fn, field)
	}
	for k := range fields {
		if k != "task" && k != "workbench" {
			return nil, validationf("%s(): %s: unknown field %q", fn, field, k)
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
	return nil, validationf("%s(): %s.workbench must be a workbench id or name", fn, field)
}

// replyAction validates a reply's value and its optional data object.
func replyAction(fn, field string, fields map[string]any, a *db.InboxAction) error {
	s, ok := fields["reply"].(string)
	if !ok || s == "" {
		return validationf("%s(): %s.reply must be a non-empty string", fn, field)
	}
	if n := utf8.RuneCountInString(s); n > MaxInboxReplyValueChars {
		return validationf("%s(): %s.reply is %d characters; the limit is %d", fn, field, n, MaxInboxReplyValueChars)
	}
	a.Reply = s
	d, has := fields["data"]
	if !has {
		return nil
	}
	if _, isObject := d.(map[string]any); !isObject {
		return validationf("%s(): %s.data must be an object", fn, field)
	}
	b, err := json.Marshal(d)
	if err != nil {
		return validationf("%s(): %s.data: %v", fn, field, err)
	}
	if len(b) > MaxInboxActionDataBytes {
		return validationf("%s(): %s.data is %d bytes of JSON; the limit is %d", fn, field, len(b), MaxInboxActionDataBytes)
	}
	a.Data = b
	return nil
}

// checkCardURL admits a card link: an http, https or watchtower-nav URL
// (the scheme in any case) with a host, at most MaxInboxLinkBytes long.
func checkCardURL(fn, field, raw string) (string, error) {
	if len(raw) > MaxInboxLinkBytes {
		return "", validationf("%s(): %s is %d bytes; the limit is %d", fn, field, len(raw), MaxInboxLinkBytes)
	}
	u, err := url.Parse(raw)
	if err != nil || !slices.Contains(cardURLSchemes, strings.ToLower(u.Scheme)) || u.Host == "" {
		return "", validationf("%s(): %s must be an http, https or watchtower-nav:// link with a host", fn, field)
	}
	return raw, nil
}
