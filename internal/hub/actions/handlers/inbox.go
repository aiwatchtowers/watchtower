package handlers

import (
	"context"
	"encoding/json"
	"log"

	"watchtower/internal/hub/actions"
	"watchtower/internal/inboxfeed"
	"watchtower/internal/policy"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
)

// inboxActKind is the phone Inbox's one action kind (mobile Inbox spec §6):
// its params are the generated inbox.act request, and it runs through the
// daemon's tower like the Mac's own call.
const inboxActKind = "inbox_act"

// The inbox_act refusals the hub words itself (the tower words its own).
const (
	inboxPermissionsNotAllowedMsg = "This phone is not allowed to decide on proposals"
	inboxTypingNotAllowedMsg      = "This phone is not allowed to send replies"
	inboxPolicyMsg                = "The Inbox stays on your Mac"
	inboxNoTowerMsg               = "Update Watchtower on your tower to use the Inbox from the phone"
	inboxParamsMsg                = "This Inbox action could not be read"
	inboxUnknownMsg               = "Your tower did not confirm this — check on the Mac"
	inboxGrantsUnreadableMsg      = "Your tower could not read this phone's permissions — try again"
)

// inboxActOptions are inbox_act's kind options: an approve, a retry, a press
// or a Run Now is claimed begun before the handler (outcome_unknown, never
// run again, when the hub stops mid-call); the guarded verbs are not, so a
// redelivery reaches the tower, whose ledger answers the stored result.
func inboxActOptions() actions.KindOptions {
	return actions.KindOptions{
		Nudges: nudgeNames(inboxActKind),
		NonIdempotentFor: func(params json.RawMessage) bool {
			ok, _ := inboxfeed.ActIdempotent(params)
			return !ok
		},
	}
}

// inboxAct runs one phone Inbox write: the grant its verb needs
// (inboxfeed.ActGrant: permissions or typing), then inbox.act through the
// tower as the hub (Origin.Transport "hub": the tower admits the owner's
// gestures by these grants and refuses what stays on the Mac). ok is
// applied with the act's result; refused is failed with the tower's sentence
// and its code in result.code; unknown is outcome_unknown.
func (h *Handlers) inboxAct(ctx context.Context, r actions.Request) actions.Outcome {
	return h.withTimeout(ctx, inboxActKind, inboxUnknownMsg, func(ctx context.Context) actions.Outcome {
		return h.applyInboxAct(ctx, r)
	})
}

func (h *Handlers) applyInboxAct(ctx context.Context, r actions.Request) actions.Outcome {
	if h.d.Policy != nil && h.d.Policy() != policy.MobileAllowed {
		return failed(reasonNotSupported, inboxPolicyMsg)
	}
	if h.d.Tower == nil {
		return failed(reasonNotSupported, inboxNoTowerMsg)
	}
	params, err := json.Marshal(r.Action.Params)
	if err != nil {
		return failed(reasonInvalidParams, inboxParamsMsg)
	}
	grant, err := inboxfeed.ActGrant(params)
	if err != nil {
		return failed(reasonInvalidParams, inboxParamsMsg)
	}
	if o, ok := h.inboxGrant(r, grant); !ok {
		return o
	}
	resp := h.d.Tower.Call(ctx, api.Request{V: api.EnvelopeVersion, ID: r.RecordName, Command: "inbox.act", Params: params},
		tower.Origin{Transport: "hub", Device: r.Device.String()})
	switch resp.Status {
	case api.StatusOK:
		var result map[string]any
		if len(resp.Result) > 0 {
			if err := json.Unmarshal(resp.Result, &result); err != nil {
				return failed(reasonWriteFailed, "")
			}
		}
		return applied(result)
	case api.StatusRefused:
		if resp.Refusal == nil {
			return failed(reasonNotSupported, "")
		}
		o := failed(refusalReason(resp.Refusal.Code), resp.Refusal.Sentence)
		o.Result = map[string]any{"code": string(resp.Refusal.Code)}
		return o
	default:
		return failed(reasonOutcomeUnknown, inboxUnknownMsg)
	}
}

// inboxGrant checks the device's grant for an inbox_act that needs one: ok
// is false with the device_not_allowed outcome when it lacks it.
func (h *Handlers) inboxGrant(r actions.Request, grant string) (actions.Outcome, bool) {
	if grant == "" {
		return actions.Outcome{}, true
	}
	d, linked, err := h.d.Store.Device(r.Device.String())
	if err != nil {
		log.Printf("hub handlers: inbox_act: the device grants are unreadable")
		return failed(reasonWriteFailed, inboxGrantsUnreadableMsg), false
	}
	switch {
	case grant == "permissions" && (!linked || !d.PermissionsAllowed):
		return failed(reasonDeviceNotAllowed, h.withServerAllowStep(inboxPermissionsNotAllowedMsg, r.Device, grant)), false
	case grant == "typing" && (!linked || !d.TypingAllowed):
		return failed(reasonDeviceNotAllowed, h.withServerAllowStep(inboxTypingNotAllowedMsg, r.Device, grant)), false
	case grant != "permissions" && grant != "typing":
		// A grant this hub does not know is never given.
		return failed(reasonDeviceNotAllowed, inboxPermissionsNotAllowedMsg), false
	}
	return actions.Outcome{}, true
}

// refusalReason is the wire reason of a tower refusal (the code itself goes
// in result.code, which the phone's Inbox reads).
func refusalReason(code api.RefusalCode) string {
	switch code {
	case api.CodeNotFound:
		return reasonNotFound
	case api.CodeChanged, api.CodeArgsChanged, api.CodeReplyWaiting:
		return reasonConflict
	default: // not_permitted, unsupported: the sentence says what to do
		return reasonNotSupported
	}
}
