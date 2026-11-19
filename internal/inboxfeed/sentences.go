package inboxfeed

import (
	"errors"

	"watchtower/internal/db"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
)

// Every inbox.act refusal reads "Couldn't <verb phrase>: <reason>", written
// here in Go; both clients show it as is (spec §4.3).

// verbPhrases are the verb phrases, keyed by verbKey: the act verb, or
// "ref:<ref verb>" and "approval:<approval verb>".
var verbPhrases = map[string]string{
	"read":             "mark it read",
	"done":             "mark it done",
	"dismiss":          "dismiss it",
	"press":            "do that",
	"run_now":          "run it now",
	"reply_propose":    "send the reply",
	"ref:resolve":      "resolve it",
	"ref:dismiss":      "dismiss it",
	"ref:snooze":       "snooze",
	"ref:done":         "mark it done",
	"ref:stop":         "stop watching",
	"ref:restore":      "restore it",
	"ref:make_task":    "make the task",
	"ref:approve":      "approve it",
	"ref:reject":       "reject it",
	"ref:not_now":      "put it off",
	"ref:check":        "check it off",
	"ref:uncheck":      "uncheck it",
	"approval:approve": "approve it",
	"approval:reject":  "reject it",
	"approval:retry":   "try again",
	"approval:dismiss": "dismiss it",
}

// The reasons, one per refusal code (codeReason), and the narrower ones a
// verb picks.
const (
	reasonChanged      = "this card changed — look again."
	reasonIdeaChanged  = "this idea changed — look again."
	reasonClosed       = "the item was already closed on the Mac."
	reasonNotFound     = "it's no longer on the Mac."
	reasonReplyWaiting = "a reply already waits in Needs approval."
	reasonNotPermitted = "edit this proposal on the Mac."
	reasonUnsupported  = "this card doesn't offer that here."
	reasonNoService    = "this Watchtower can't do that here — update the app."
	// reasonOwnerDesktop refuses an AGENT-07 gesture over the socket from
	// any peer but the signed Watchtower Desktop.
	reasonOwnerDesktop = "the owner decides in Watchtower Desktop."
	// reasonOnTheMac refuses, from the phone, what stays on the Mac (ask
	// #1349: turning automations on or off).
	reasonOnTheMac = "this is done on the Mac."
	// noteWatchOnMac is the note of a create_track approved from the phone:
	// its watch is started from the Mac.
	noteWatchOnMac = "Start watching it from your Mac."
	reasonBusy     = "the database is busy."
	reasonFault    = "something went wrong on the Mac — try again."
	// sentenceArgsChanged is the whole args_changed sentence (mockup §6).
	sentenceArgsChanged = "This proposal changed on the Mac — look again before approving."
)

// codeReason is each refusal code's own reason.
var codeReason = map[api.RefusalCode]string{
	api.CodeNotFound:     reasonNotFound,
	api.CodeChanged:      reasonChanged,
	api.CodeArgsChanged:  sentenceArgsChanged,
	api.CodeReplyWaiting: reasonReplyWaiting,
	api.CodeNotPermitted: reasonNotPermitted,
	api.CodeUnsupported:  reasonUnsupported,
}

// verbKey is a request's key into verbPhrases.
func verbKey(req api.ActRequest) string {
	switch req.Verb {
	case api.ActRef:
		return "ref:" + string(req.Params.RefVerb)
	case api.ActApproval:
		return "approval:" + string(req.Params.ApprovalVerb)
	default:
		return string(req.Verb)
	}
}

// phrase is a request's verb phrase; an unknown verb reads "do that".
func phrase(req api.ActRequest) string {
	if p, ok := verbPhrases[verbKey(req)]; ok {
		return p
	}
	return "do that"
}

// Sentence is a refusal's sentence: "Couldn't <phrase>: <reason>", reason
// "" meaning the code's own. args_changed has its own whole sentence.
func Sentence(req api.ActRequest, code api.RefusalCode, reason string) string {
	if code == api.CodeArgsChanged {
		return sentenceArgsChanged
	}
	if reason == "" {
		reason = codeReason[code]
	}
	return "Couldn't " + phrase(req) + ": " + reason
}

// refuse refuses req with code (reason "" = the code's own).
func refuse(req api.ActRequest, code api.RefusalCode, reason string) error {
	return tower.Refuse(code, Sentence(req, code, reason))
}

// actFault carries a fault (not a refusal) of an inbox.act call with its
// verb phrase, so FaultSentence words it as the verb's.
type actFault struct {
	phrase string
	err    error
}

func (e *actFault) Error() string { return e.err.Error() }
func (e *actFault) Unwrap() error { return e.err }

// faultOf wraps a handler's error: a refusal passes as is, any other error
// carries req's verb phrase.
func faultOf(req api.ActRequest, err error) error {
	var r *tower.RefusalError
	if err == nil || errors.As(err, &r) {
		return err
	}
	return &actFault{phrase: phrase(req), err: err}
}

// FaultSentence is tower.Options.Sentence: a fault's sentence for the owner.
// An inbox.act fault reads "Couldn't <phrase>: <reason>", any other
// command's "Watchtower couldn't do that: <reason>"; the reason is "the
// database is busy." for SQLITE_BUSY, else a generic one (the error itself
// belongs in the daemon's log, not on the owner's screen).
func FaultSentence(_ string, err error) string {
	reason := reasonFault
	if db.IsBusy(err) {
		reason = reasonBusy
	}
	var f *actFault
	if errors.As(err, &f) {
		return "Couldn't " + f.phrase + ": " + reason
	}
	return "Watchtower couldn't do that: " + reason
}
