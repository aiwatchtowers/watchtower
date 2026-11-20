package inboxfeed

import (
	"errors"
	"fmt"
	"testing"

	"watchtower/internal/sqlcipher"
	"watchtower/internal/tower/api"
)

// TestSentences_EveryVerbHasAPhrase: every act verb, ref verb and approval
// verb has its phrase, and every refusal code its reason.
func TestSentences_EveryVerbHasAPhrase(t *testing.T) {
	var keys []string
	for _, v := range api.ActVerb("").EnumValues() {
		switch api.ActVerb(v) {
		case api.ActRef:
			for _, r := range api.RefVerb("").EnumValues() {
				keys = append(keys, "ref:"+r)
			}
		case api.ActApproval:
			for _, a := range api.ApprovalVerb("").EnumValues() {
				keys = append(keys, "approval:"+a)
			}
		default:
			keys = append(keys, v)
		}
	}
	for _, k := range keys {
		if verbPhrases[k] == "" {
			t.Errorf("verb %s has no phrase", k)
		}
	}
	if len(verbPhrases) != len(keys) {
		t.Errorf("%d phrases for %d verbs: a phrase names no verb", len(verbPhrases), len(keys))
	}
	for _, c := range api.RefusalCode("").EnumValues() {
		if codeReason[api.RefusalCode(c)] == "" {
			t.Errorf("code %s has no reason", c)
		}
	}
}

// TestSentences_MockupSentences pins the four sentences of the mockup.
func TestSentences_MockupSentences(t *testing.T) {
	snooze := api.ActRequest{Verb: api.ActRef, Params: api.ActParams{RefVerb: api.RefSnooze}}
	done := api.ActRequest{Verb: api.ActDone}
	approveIdea := api.ActRequest{Verb: api.ActRef, Params: api.ActParams{RefVerb: api.RefApprove}}
	approve := api.ActRequest{Verb: api.ActApproval, Params: api.ActParams{ApprovalVerb: api.ApprovalApprove}}
	busy := faultOf(done, fmt.Errorf("commit: %w", sqlcipher.Error{Code: sqlcipher.ErrBusy}))
	for got, want := range map[string]string{
		Sentence(snooze, api.CodeChanged, reasonClosed):           "Couldn't snooze: the item was already closed on the Mac.",
		Sentence(approve, api.CodeArgsChanged, ""):                "This proposal changed on the Mac — look again before approving.",
		FaultSentence("inbox.act", busy):                          "Couldn't mark it done: the database is busy.",
		Sentence(approveIdea, api.CodeChanged, reasonIdeaChanged): "Couldn't approve it: this idea changed — look again.",
		Sentence(done, api.CodeChanged, ""):                       "Couldn't mark it done: this card changed — look again.",
	} {
		if got != want {
			t.Errorf("got %q, want %q", got, want)
		}
	}
	if got := FaultSentence("tower.hello", errors.New("boom")); got != "Watchtower couldn't do that: something went wrong on the Mac — try again." {
		t.Errorf("another command's fault: %q", got)
	}
}
