package automations

import (
	"errors"

	"watchtower/internal/automations/blocks"
	"watchtower/internal/db"
)

// An Inbox card's own fields (panel and Inbox spec B2): output.inbox takes
// an optional source link and up to MaxInboxActions buttons in the one
// action grammar of internal/automations/blocks (blocks.ValidateAction),
// shared with the actions inside a card's blocks. A Reply action needs
// inbox:reply and a Target action outputs: [target].

// inboxCard validates output.inbox's link and actions. Actions is never
// nil.
func inboxCard(env *Env, fn string, fields map[string]any) (link string, actions []db.InboxAction, err error) {
	if raw, has := fields["link"]; has {
		s, ok := raw.(string)
		if !ok {
			return "", nil, validationf("%s(): link must be a string", fn)
		}
		if link, err = blocks.CheckURL(fn, "link", s); err != nil {
			return "", nil, blockError(err)
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
	opts := blocks.Options{AllowKind: allowActionKind(env, fn)}
	for i, v := range list {
		a, err := blocks.ValidateAction(fn, "actions", i, v, opts)
		if err != nil {
			return "", nil, blockError(err)
		}
		actions = append(actions, a)
	}
	return link, actions, nil
}

// allowActionKind is the manifest's check of an action kind: a Reply
// action needs inbox:reply, a Target action outputs: [target]; every other
// kind needs nothing beyond the output's own gate.
func allowActionKind(env *Env, fn string) func(kind string) error {
	return func(kind string) error {
		if kind != db.InboxActionReply && kind != db.InboxActionTarget {
			return nil
		}
		m, err := manifestOf(env)
		if err != nil {
			return err
		}
		if kind == db.InboxActionReply {
			_, err = m.AllowInboxReply()
			return err
		}
		if _, err := m.AllowOutput("target"); err != nil {
			return &PermissionDenied{Needed: "output:target", Reason: fn + "(): a target action needs outputs: [target]"}
		}
		return nil
	}
}

// blockError turns a blocks validation refusal into the ValidationError
// the script sees; any other error (a permission denial) passes unchanged.
func blockError(err error) error {
	var be *blocks.Error
	if errors.As(err, &be) {
		return validationf("%s", be.Msg)
	}
	return err
}
