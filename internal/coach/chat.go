package coach

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"slices"
	"strings"
	"unicode/utf8"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/prompts"
)

// ChatEdit is one edit the tuning chat (propose_tuning_edit) asks for.
type ChatEdit struct {
	Destination         string
	WorkbenchID         int64
	PromptID, Skill     string
	Kind, Find, Replace string
	Title, Why, Metric  string
	// Evidence are the refs the chat cites; the caller includes "c<conversation>".
	Evidence []string
}

// ErrRefused matches every refusal of ValidateChatProposal: errors.Is(err,
// ErrRefused) holds, and Error() is the plain reason only, for the chat to
// show as is.
var ErrRefused = errors.New("proposal refused")

// refusal is a refused proposal: its text is the reason.
type refusal string

func (r refusal) Error() string        { return string(r) }
func (r refusal) Is(target error) bool { return target == ErrRefused }

func refuse(format string, args ...any) error { return refusal(fmt.Sprintf(format, args...)) }

// ValidateChatProposal checks one chat edit against its destination's current
// text and returns the proposal ready for db.InsertChatCoachProposal (the
// caller sets ConversationID). Unlike the weekly Validate it has no source
// floor and takes no weekly slot; it still refuses an edit already proposed
// and a text another open proposal edits. Every refusal matches ErrRefused;
// a cancelled ctx or a read failure is returned as is.
func ValidateChatProposal(ctx context.Context, d *db.DB, e ChatEdit, env Env) (db.CoachProposal, error) {
	if err := ctx.Err(); err != nil {
		return db.CoachProposal{}, err
	}
	dest := e.Destination
	if !chatDestinations[dest] {
		return db.CoachProposal{}, refuse("destination %q cannot be edited from the chat", dest)
	}
	title, why := oneLine(e.Title), strings.TrimSpace(e.Why)
	switch {
	case title == "" || why == "":
		return db.CoachProposal{}, refuse("title and why are required")
	case utf8.RuneCountInString(title) > maxTitleRunes:
		return db.CoachProposal{}, refuse("title is over %d characters", maxTitleRunes)
	case utf8.RuneCountInString(why) > maxWhyRunes:
		return db.CoachProposal{}, refuse("why is over %d characters", maxWhyRunes)
	case !proposalKinds[e.Kind]:
		return db.CoachProposal{}, refuse("kind must be add, cut or replace")
	case !metrics[e.Metric]:
		return db.CoachProposal{}, refuse("metric must be corrections, task_cost, owner_loop or review_findings")
	}
	if err := checkChatArgs(d, e); err != nil {
		return db.CoachProposal{}, err
	}
	if dest == DestPromptAdd {
		if err := PromptAdditionRefusal(e.PromptID); err != nil {
			return db.CoachProposal{}, err
		}
	}
	if skillDestinations[dest] {
		if err := checkChatSkill(dest, e.Skill); err != nil {
			return db.CoachProposal{}, err
		}
	}
	key := keyOf(dest, e.WorkbenchID, e.PromptID, e.Skill)
	cur, err := ReadText(d, env, key.dest, key.wb, key.prompt, key.skill)
	if err != nil {
		return db.CoachProposal{}, readRefusal(err, key.skill)
	}
	after, err := applyChatEdit(cur, e.Find, e.Replace)
	if err != nil {
		return db.CoachProposal{}, err
	}
	switch {
	case after == cur.Text:
		return db.CoachProposal{}, refuse("the edit changes nothing")
	case !kindFits(e.Kind, cur.Text, after):
		return db.CoachProposal{}, refuse("kind %s does not fit the edit", e.Kind)
	}
	if err := ValidateAfter(cur, after); err != nil {
		return db.CoachProposal{}, refusal(err.Error())
	}
	fp, changed := fingerprint(key, cur.Text, after)
	if !changed {
		return db.CoachProposal{}, refuse("the edit changes only spacing, case or punctuation")
	}
	switch prev, err := d.CoachProposalByFingerprint(fp); {
	case err == nil:
		return db.CoachProposal{}, refuse("already proposed as #%d (%s)", prev.ID, prev.Status)
	case !errors.Is(err, sql.ErrNoRows):
		return db.CoachProposal{}, err
	}
	open, err := d.ListCoachProposals("open")
	if err != nil {
		return db.CoachProposal{}, err
	}
	for _, p := range open {
		if keyOf(p.Destination, p.WorkbenchID, p.PromptID, p.Skill) == key {
			return db.CoachProposal{}, refuse("proposal #%d is already open for this text — decide it first", p.ID)
		}
	}
	evidence, sources := chatEvidence(e.Evidence)
	return db.CoachProposal{Origin: "chat", Fingerprint: fp, Kind: e.Kind, Destination: key.dest,
		WorkbenchID: key.wb, PromptID: key.prompt, Skill: key.skill, Title: title, Why: why, Metric: e.Metric,
		BeforeText: cur.Text, AfterText: after, Evidence: evidence, Sources: sources}, nil
}

// checkChatArgs refuses arguments the destination does not take or misses,
// and a workbench that does not exist.
func checkChatArgs(d *db.DB, e ChatEdit) error {
	dest := e.Destination
	switch {
	case dest == DestPromptAdd && e.PromptID == "":
		return refuse("prompt_addition needs prompt_id")
	case skillDestinations[dest] && e.Skill == "":
		return refuse("%s needs skill", dest)
	case dest != DestPromptAdd && e.PromptID != "":
		return refuse("%s takes no prompt_id", dest)
	case !skillDestinations[dest] && e.Skill != "":
		return refuse("%s takes no skill", dest)
	case globalDestinations[dest] && e.WorkbenchID != 0:
		return refuse("%s has no per-workbench text", dest)
	}
	if e.WorkbenchID != 0 {
		if _, err := d.GetWorkbench(e.WorkbenchID); err != nil {
			if errors.Is(err, db.ErrWorkbenchNotFound) {
				return refuse("workbench %d not found", e.WorkbenchID)
			}
			return err
		}
	}
	return nil
}

// PromptAdditionRefusal is nil for a prompt the owner's additions reach, else
// the refusal naming why not.
func PromptAdditionRefusal(id string) error {
	if _, ok := prompts.Defaults[id]; !ok {
		return refuse("unknown prompt %s", id)
	}
	if _, moved := prompts.MovedToBuiltin[id]; moved {
		return refuse("%s belongs to a built-in automation", id)
	}
	if !prompts.TakesAdditions(id) {
		return refuse("%s does not take additions", id)
	}
	return nil
}

// checkChatSkill refuses a bad skill name, an overlay of a skill the pack does
// not ship and a user-skill edit of a pack skill.
func checkChatSkill(dest, name string) error {
	if checkSkillName(name) != nil {
		return refuse("%q is not a skill name", name)
	}
	pack := slices.Contains(devpack.PackSkillNames(), name)
	switch {
	case dest == DestPackOverlay && !pack:
		return refuse("%s is not a Watchtower pack skill", name)
	case dest != DestPackOverlay && pack:
		return refuse("%s is a Watchtower pack skill: propose a pack_overlay", name)
	}
	return nil
}

// readRefusal maps the read errors the owner can act on to refusals with
// their own text (they name the file's label, never its path); any other
// error is returned as is.
func readRefusal(err error, skill string) error {
	switch {
	case errors.Is(err, errSkillNotFound):
		return refuse("skill %s not found", skill)
	case errors.Is(err, errPackSkill):
		return refuse("%s is a Watchtower pack skill: propose a pack_overlay", skill)
	case errors.Is(err, errUnsafeFile), errors.Is(err, errCodexRulesMissing), errors.Is(err, errCodexSkillTwice),
		errors.Is(err, errClaudeMDNotRegular), errors.Is(err, errClaudeMDTooBig),
		errors.Is(err, errSettingsNotRegular), errors.Is(err, errSettingsInvalid):
		return refusal(err.Error())
	}
	return err
}

// applyChatEdit is applyEdit with a refusal for each way find fails, and
// whole lines for every destination (the weekly pass asks it only of the line
// destinations).
func applyChatEdit(cur CurrentText, find, replace string) (string, error) {
	if find != "" {
		i := strings.Index(cur.Text, find)
		if i < 0 {
			return "", refuse("find matches no text")
		}
		if n := strings.Count(cur.Text, find); n > 1 {
			return "", refuse("find matches %d times; it must match once", n)
		}
		if !wholeLines(cur.Text, i, i+len(find)) {
			return "", refuse("find must cover whole lines")
		}
		if cur.Destination == DestSettingsAllow || cur.Destination == DestCodexRulesAllow {
			return "", refuse("the allow rules may only grow: leave find empty")
		}
	}
	after, ok := applyEdit(cur, find, replace)
	if !ok {
		// Only an empty append is left: it changes nothing.
		return "", refuse("the edit changes nothing")
	}
	return after, nil
}

// chatEvidence keeps the refs of a known shape (deduplicated, in order, at
// most maxEvidence stored) and counts their distinct sources.
func chatEvidence(cited []string) ([]db.CoachEvidence, int) {
	known := map[string]bool{}
	for _, ref := range cited {
		ref = strings.TrimSpace(ref)
		if kind, _ := sourceOf(ref); kind != "" {
			known[ref] = true
		}
	}
	return citedEvidence(cited, known)
}

// ReadText is the destination's current text, read the way Accept reads it.
func ReadText(d *db.DB, env Env, dest string, wb int64, prompt, skill string) (CurrentText, error) {
	a := &Applier{DB: d, Home: env.Home, CodexHome: env.CodexHome}
	return a.readCurrent(db.CoachProposal{Destination: dest, WorkbenchID: wb, PromptID: prompt, Skill: skill})
}
