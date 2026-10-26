package coach

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/agentreport"
	"watchtower/internal/db"
	"watchtower/internal/instructions"
	"watchtower/internal/prompts"
	"watchtower/internal/specreview"
)

const (
	// signalWindow is how far back the weekly pass reads its signals.
	signalWindow = 28 * 24 * time.Hour
	// maxSignals caps the signals handed to the model; the newest are kept.
	maxSignals = 400
	// maxSignalRunes cuts one signal's text.
	maxSignalRunes = 600
)

// Signal kinds.
const (
	KindSpecReal   = "spec_real"
	KindSpecNoise  = "spec_noise"
	KindCodeReview = "code_review"
	KindOwnerLine  = "owner_line"
	KindHint       = "hint"
)

// Text destinations of CurrentText (the coach_proposals.destination values).
const (
	DestSession       = "session"
	DestProcedure     = "procedure"
	DestChat          = "chat"
	DestPromptAdd     = "prompt_addition"
	DestSettingsAllow = "claude_settings_allow"
)

// Signal is one piece of evidence the model may cite. Ref is the citation key
// the model's output is validated against: "ask:<id>#<item key>" (a spec
// review finding), "s<id>" (a workbench session's owner line), "c<id>" (an AI
// chat's), "round:<id>#c<comment id>" (a first-round review comment),
// "hint:<hint id>@wb<workbench id>" (an agentreport hint).
type Signal struct {
	Ref         string
	Kind        string
	WorkbenchID int64
	Text        string

	at time.Time
}

// CurrentText is one editable destination as it stands. WorkbenchID 0 is
// global. Budget is the destination's rune budget; 0 means it is not a text
// budget (the settings allow list).
type CurrentText struct {
	Destination string
	WorkbenchID int64
	PromptID    string
	Text        string
	Budget      int
}

// Inputs is everything the weekly pass shows the model. Accepted are the
// accepted proposals without a no-effect verdict, NoEffect those whose verdict
// is no_effect (accepted or rolled back).
type Inputs struct {
	Signals                            []Signal
	Texts                              []CurrentText
	Open, Declined, Accepted, NoEffect []db.CoachProposal
}

// userHomeDir is the home directory ~/.claude/settings.json is read from; a
// seam so tests never read the real one.
var userHomeDir = os.UserHomeDir

// Collect gathers the weekly pass's inputs over the last signalWindow. al may
// be nil (no hint signals). Owner text is never logged (FILES-01).
func Collect(ctx context.Context, d *db.DB, al *agentlogdb.DB, read instructions.FeedReader, now time.Time) (Inputs, error) {
	if err := ctx.Err(); err != nil {
		return Inputs{}, err
	}
	since := now.Add(-signalWindow)
	var in Inputs
	var sigs []Signal

	spec, err := specSignals(d, since, now)
	if err != nil {
		return Inputs{}, err
	}
	sigs = append(sigs, spec...)

	comments, err := d.ListFirstRoundReviewCommentsBetween(since, now)
	if err != nil {
		return Inputs{}, err
	}
	for _, c := range comments {
		sigs = append(sigs, Signal{Ref: fmt.Sprintf("round:%d#c%d", c.RoundID, c.CommentID), Kind: KindCodeReview,
			WorkbenchID: c.WorkbenchID, Text: c.Body, at: c.CreatedAt})
	}

	lines, err := instructions.CollectOwnerLines(d, read, since)
	if err != nil {
		return Inputs{}, err
	}
	for _, l := range lines {
		ref := fmt.Sprintf("s%d", l.SessionID)
		if l.ChatID != 0 {
			ref = fmt.Sprintf("c%d", l.ChatID)
		}
		sigs = append(sigs, Signal{Ref: ref, Kind: KindOwnerLine, WorkbenchID: l.WorkbenchID, Text: l.Text, at: l.At()})
	}

	if al != nil {
		hints, err := hintSignals(d, al, since, now)
		if err != nil {
			return Inputs{}, err
		}
		sigs = append(sigs, hints...)
	}

	in.Signals = capSignals(sigs)

	if in.Texts, err = currentTexts(d); err != nil {
		return Inputs{}, err
	}
	if err := loadProposals(d, &in); err != nil {
		return Inputs{}, err
	}
	return in, nil
}

// specSignals turns the owner's marks on finished spec reviews into signals: a
// comment mark is a real problem, a not-useful mark is noise, any other mark
// (and no mark) is skipped. Ref is "ask:<id>#<item key>".
func specSignals(d *db.DB, since, until time.Time) ([]Signal, error) {
	reviews, err := d.ListDoneSpecReviewsBetween(since, until)
	if err != nil {
		return nil, err
	}
	var out []Signal
	for _, r := range reviews {
		marks, err := d.ListSpecReviewMarks(r.AskID)
		if err != nil {
			return nil, err
		}
		if len(marks) == 0 {
			continue
		}
		var res specreview.Result
		if err := json.Unmarshal([]byte(r.Result), &res); err != nil {
			// The row is malformed: say which one, never what it held.
			return nil, fmt.Errorf("decoding spec review of ask %d: %w", r.AskID, err)
		}
		items := findingTexts(res)
		for key, m := range marks {
			var kind string
			switch m.State {
			case "comment":
				kind = KindSpecReal
			case db.SpecReviewMarkNotUseful:
				kind = KindSpecNoise
			default:
				continue
			}
			text := items[key]
			if text == "" {
				text = m.About
			}
			if text == "" {
				continue
			}
			if kind == KindSpecReal && strings.TrimSpace(m.Body) != "" {
				text += " | owner: " + m.Body
			}
			out = append(out, Signal{Ref: fmt.Sprintf("ask:%d#%s", r.AskID, key), Kind: kind,
				WorkbenchID: r.WorkbenchID, Text: text, at: r.FinishedAt})
		}
	}
	return out, nil
}

// findingTexts maps each item key of a review result to the text the owner saw.
func findingTexts(r specreview.Result) map[string]string {
	m := map[string]string{}
	join := func(parts ...string) string {
		var keep []string
		for _, p := range parts {
			if p = strings.TrimSpace(p); p != "" {
				keep = append(keep, p)
			}
		}
		return strings.Join(keep, " - ")
	}
	for _, a := range r.Agreements {
		m[a.Key] = join(a.Text, a.Note)
	}
	for _, a := range r.DecidedAlone {
		m[a.Key] = join(a.Text, a.Note)
	}
	for _, b := range r.BlindSpots {
		m[b.Key] = join(b.Text, b.Why)
	}
	for _, c := range r.Checks {
		m[c.Key] = join(c.Question, c.Note)
	}
	return m
}

// hintSignals turns the agentreport hints of each analytics-on workbench that
// carry an Action into signals (Ref "hint:<id>@wb<workbench>").
func hintSignals(d *db.DB, al *agentlogdb.DB, since, now time.Time) ([]Signal, error) {
	ids, err := d.AgentAnalyticsWorkbenchIDs()
	if err != nil {
		return nil, fmt.Errorf("listing workbenches with analytics: %w", err)
	}
	var out []Signal
	for _, id := range ids {
		ov, err := agentreport.BuildOverview(d, al, id, since, now, agentreport.English)
		if err != nil {
			return nil, fmt.Errorf("building overview of workbench %d: %w", id, err)
		}
		for _, h := range ov.Hints {
			if strings.TrimSpace(h.Action) == "" {
				continue
			}
			out = append(out, Signal{Ref: fmt.Sprintf("hint:%s@wb%d", h.ID, id), Kind: KindHint, WorkbenchID: id,
				Text: strings.TrimSpace(h.Finding) + " Action: " + strings.TrimSpace(h.Action), at: now})
		}
	}
	return out, nil
}

// capSignals orders the signals newest first (ties by ref, then text), keeps
// maxSignals and cuts each text to maxSignalRunes.
func capSignals(sigs []Signal) []Signal {
	sort.SliceStable(sigs, func(i, j int) bool {
		a, b := sigs[i], sigs[j]
		if !a.at.Equal(b.at) {
			return a.at.After(b.at)
		}
		if a.Ref != b.Ref {
			return a.Ref < b.Ref
		}
		return a.Text < b.Text
	})
	if len(sigs) > maxSignals {
		sigs = sigs[:maxSignals]
	}
	for i := range sigs {
		sigs[i].Text = cutRunes(sigs[i].Text, maxSignalRunes)
	}
	return sigs
}

func cutRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}

// currentTexts lists every owner text field (global session, procedure and
// chat; each workbench's session and procedure), each prompt's additions as
// one text per id, and the allow list of ~/.claude/settings.json.
func currentTexts(d *db.DB) ([]CurrentText, error) {
	var out []CurrentText
	g, err := d.GetOwnerInstructions()
	if err != nil {
		return nil, err
	}
	out = append(out,
		CurrentText{Destination: DestSession, Text: g.Session, Budget: instructions.MaxRunes},
		CurrentText{Destination: DestProcedure, Text: g.Procedure, Budget: instructions.MaxRunes},
		CurrentText{Destination: DestChat, Text: g.Chat, Budget: instructions.MaxRunes})
	wbs, err := d.ListWorkbenches()
	if err != nil {
		return nil, err
	}
	for _, w := range wbs {
		t, err := d.GetWorkbenchInstructions(w.ID)
		if err != nil {
			return nil, err
		}
		out = append(out,
			CurrentText{Destination: DestSession, WorkbenchID: w.ID, Text: t.Session, Budget: instructions.MaxRunes},
			CurrentText{Destination: DestProcedure, WorkbenchID: w.ID, Text: t.Procedure, Budget: instructions.MaxRunes})
	}
	for _, id := range prompts.AllIDs {
		if _, moved := prompts.MovedToBuiltin[id]; moved {
			continue
		}
		adds, err := d.ListPromptAdditions(id)
		if err != nil {
			return nil, err
		}
		if len(adds) == 0 && id != prompts.SpecReview {
			continue // the spec reviewer is always shown: it is the main target
		}
		lines := make([]string, len(adds))
		for i, a := range adds {
			lines[i] = a.Text
		}
		out = append(out, CurrentText{Destination: DestPromptAdd, PromptID: id,
			Text: strings.Join(lines, "\n"), Budget: prompts.MaxAdditionRunes})
	}
	out = append(out, CurrentText{Destination: DestSettingsAllow, Text: strings.Join(readAllowList(), "\n")})
	return out, nil
}

// readAllowList reads permissions.allow of ~/.claude/settings.json, read-only.
// A missing, symlinked or unreadable file, invalid JSON or a different shape
// is an empty list: the coach then has nothing to extend.
func readAllowList() []string {
	home, err := userHomeDir()
	if err != nil || home == "" {
		return nil
	}
	path := filepath.Join(home, ".claude", "settings.json")
	if fi, err := os.Lstat(path); err != nil || !fi.Mode().IsRegular() {
		return nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var s struct {
		Permissions struct {
			Allow []string `json:"allow"`
		} `json:"permissions"`
	}
	if json.Unmarshal(raw, &s) != nil {
		return nil
	}
	return s.Permissions.Allow
}

func loadProposals(d *db.DB, in *Inputs) error {
	all, err := d.ListCoachProposals("open", "declined", "accepted", "rolled_back")
	if err != nil {
		return err
	}
	for _, p := range all {
		switch {
		case p.Verdict == "no_effect" && (p.Status == "accepted" || p.Status == "rolled_back"):
			in.NoEffect = append(in.NoEffect, p)
		case p.Status == "open":
			in.Open = append(in.Open, p)
		case p.Status == "declined":
			in.Declined = append(in.Declined, p)
		case p.Status == "accepted":
			in.Accepted = append(in.Accepted, p)
		}
	}
	return nil
}
