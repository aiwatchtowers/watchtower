// Package aiconsent decides whether Watchtower may run background AI.
//
// Background = started by a timer, a sync cycle or an event; not by the
// owner's own gesture. The owner answers once (config.yaml
// ai.background_runs: allowed | paused, written only by
// "watchtower ai background allow|pause"); the organization may force the
// AllowBackgroundAI profile key. Resolve combines the two (spec §3.2, the
// shared fixture testdata/consent_cases.json), Current reads them, and Check
// refuses a background model call that was not admitted while the state is
// not allowed.
//
// The package is a leaf: it imports internal/policy, the stdlib and yaml.v3
// only, never internal/db or internal/config.
package aiconsent

// Effective is the resolved state: background AI runs or it does not.
type Effective string

const (
	EffectiveAllowed Effective = "allowed"
	EffectivePaused  Effective = "paused"
)

// Reason says who decided the effective state.
type Reason string

const (
	ReasonUnanswered   Reason = "unanswered"
	ReasonOwner        Reason = "owner"
	ReasonOrganization Reason = "organization"
)

// Answer is the owner's stored answer; AnswerNone = not answered.
type Answer string

const (
	AnswerNone    Answer = ""
	AnswerAllowed Answer = "allowed"
	AnswerPaused  Answer = "paused"
)

// State is the effective consent with its inputs. Prompt = the consent screen
// should ask; Locked = the organization forbids it and the switch is locked.
type State struct {
	Effective Effective
	Reason    Reason
	Answer    Answer
	Policy    *bool
	Prompt    bool
	Locked    bool
}

// Allowed reports whether background AI may start.
func (s State) Allowed() bool { return s.Effective == EffectiveAllowed }

// Resolve is the pure table of spec §3.2. policy is the normalized forced
// AllowBackgroundAI (nil = no profile key; a wrong type already reads false).
// false forbids whatever the owner said; true stands in for an owner who has
// not answered and never overrides the owner's paused.
func Resolve(answer Answer, policy *bool) State {
	s := State{Answer: answer, Policy: policy}
	switch {
	case policy != nil && !*policy:
		s.Effective, s.Reason, s.Locked = EffectivePaused, ReasonOrganization, true
	case answer == AnswerAllowed:
		s.Effective, s.Reason = EffectiveAllowed, ReasonOwner
	case answer == AnswerPaused:
		s.Effective, s.Reason = EffectivePaused, ReasonOwner
	case policy != nil:
		s.Effective, s.Reason = EffectiveAllowed, ReasonOrganization
	default:
		s.Effective, s.Reason, s.Prompt = EffectivePaused, ReasonUnanswered, true
	}
	return s
}

// ParseAnswer reads the raw config value. "" is a known "not answered";
// any value other than allowed or paused is unknown and reads as not
// answered.
func ParseAnswer(raw string) (a Answer, known bool) {
	switch Answer(raw) {
	case AnswerNone, AnswerAllowed, AnswerPaused:
		return Answer(raw), true
	}
	return AnswerNone, false
}

// LogLine is the daemon's line for a paused state, logged once per state
// change; "" when allowed.
func LogLine(s State) string {
	if s.Allowed() {
		return ""
	}
	var why string
	switch s.Reason {
	case ReasonUnanswered:
		why = "not answered yet"
	case ReasonOwner:
		why = "paused by you"
	case ReasonOrganization:
		why = "turned off by your organization"
	}
	return "background AI: paused (" + why + `) — sync keeps running; allow it in Watchtower or with "watchtower ai background allow"`
}
