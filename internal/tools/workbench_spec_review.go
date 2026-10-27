package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/specreview"
)

// The spec review author loop on the tool side (spec
// 2026-10-26-spec-review-author-loop-design §1–§3): ask_owner starts a loop
// for a session-bound spec/plan ask and carries the author's replies into the
// next round; get_spec_review hands the author a finished round's findings.

// maxReplyNoteRunes caps one review reply's note.
const maxReplyNoteRunes = 500

// errOwnerHasReview refuses review_replies once the loop was revealed.
const errOwnerHasReview = "review_replies: the owner has this review now — wait for their answer"

// reviewReply is one review_replies entry; its JSON is specreview.Reply's.
type reviewReply struct {
	Key   string `json:"key" jsonschema:"the finding's key from get_spec_review"`
	Reply string `json:"reply" jsonschema:"fixed (you changed the document) or disagree (you keep it, note says why)"`
	Note  string `json:"note,omitempty" jsonschema:"fixed: what changed (optional); disagree: the reason (required); at most 500 characters"`
}

// validateReviewReplies is the stateless half of review_replies' checks.
func validateReviewReplies(a askOwnerArgs) error {
	if len(a.ReviewReplies) == 0 {
		return nil
	}
	if a.PreviousAskID == 0 || a.Kind != asks.KindReview {
		return &ValidationError{Msg: "review_replies: only on a review ask with previous_ask_id naming the spec review you answer"}
	}
	seen := map[string]bool{}
	for i, r := range a.ReviewReplies {
		key := strings.TrimSpace(r.Key)
		switch {
		case key == "":
			return &ValidationError{Msg: fmt.Sprintf("review_replies[%d]: key is required", i)}
		case seen[key]:
			return &ValidationError{Msg: fmt.Sprintf("review_replies: %s has more than one reply", key)}
		case r.Reply != specreview.ReplyFixed && r.Reply != specreview.ReplyDisagree:
			return &ValidationError{Msg: fmt.Sprintf("review_replies[%d]: reply must be fixed or disagree", i)}
		case r.Reply == specreview.ReplyDisagree && strings.TrimSpace(r.Note) == "":
			return &ValidationError{Msg: fmt.Sprintf("review_replies[%d]: disagree needs a note with the reason", i)}
		case utf8.RuneCountInString(strings.TrimSpace(r.Note)) > maxReplyNoteRunes:
			return &ValidationError{Msg: fmt.Sprintf("review_replies[%d]: note is longer than %d characters", i, maxReplyNoteRunes)}
		}
		seen[key] = true
	}
	return nil
}

// errRepliesNoLoop refuses review_replies on an ask that will not loop, which
// would otherwise drop them.
const errRepliesNoLoop = "review_replies: this ask will not start a review loop (it needs a spec or plan document, " +
	"a Watchtower session and a reviewer on this surface) — file it without review_replies"

// planAfterSpec refuses a plan review while a spec review ask of the same
// session is still open: the plan is written against the approved spec, so a
// review of it before the owner's answer is wasted.
func planAfterSpec(ctx context.Context, d *db.DB, b Binding, a askOwnerArgs, sessionEnv func() string) error {
	if a.Kind != asks.KindReview || specreview.ClassifyDoc(a.DocType, a.DocPath) != specreview.Plan {
		return nil
	}
	p, err := workbenchOf(ctx, d, b)
	if err != nil {
		return err
	}
	session, err := terminalSessionOf(d, p.ID, sessionEnv)
	if err != nil || !session.Valid {
		return err
	}
	spec, err := d.OpenSpecAskOfSession(session.Int64)
	if err != nil || spec == 0 {
		return err
	}
	return &ValidationError{Msg: fmt.Sprintf(
		"doc_type: the spec in ask #%d is not answered yet — file the plan for review after the owner approves the spec", spec)}
}

// specLoopStart decides a filed spec/plan ask's loop: nil (no loop: no
// session, or no reviewer launcher) or the round to queue with the author's
// replies. With replies, the previous ask must be an open ask whose review is
// in the author loop and every key one of its open items; without replies a
// previous ask in the author loop advances the round, a previous review the
// owner already has (loop 'owner') starts no hidden loop — the re-round is a
// classic visible review —, anything else starts round 1. A round past
// MaxLoopRounds starts no loop either. Replies on an ask that will not loop
// are refused (in fileAsk, where loop is known; Scope passes loop=false and
// checks only the previous ask). Called from Scope and again in fileAsk (the
// loop may have been revealed in between).
func specLoopStart(d *db.DB, a askOwnerArgs, prev *db.OwnerAsk, loop bool) (*db.SpecLoopStart, error) {
	var row *db.SpecReview
	if prev != nil {
		r, err := d.GetSpecReview(prev.ID)
		switch {
		case errors.Is(err, db.ErrSpecReviewNotFound):
		case err != nil:
			return nil, err
		default:
			row = r
		}
	}
	if len(a.ReviewReplies) > 0 {
		if err := checkRepliesAgainst(a.ReviewReplies, prev, row); err != nil {
			return nil, err
		}
	}
	if !loop {
		return nil, nil
	}
	start := &db.SpecLoopStart{Round: 1}
	switch {
	case row != nil && row.Loop == "owner":
		return nil, nil
	case row != nil && row.Loop == "author":
		start.Round = row.Round + 1
	}
	if start.Round > specreview.MaxLoopRounds {
		return nil, nil
	}
	if len(a.ReviewReplies) > 0 {
		replies := make([]specreview.Reply, 0, len(a.ReviewReplies))
		for _, r := range a.ReviewReplies {
			replies = append(replies, specreview.Reply{Key: strings.TrimSpace(r.Key), Reply: r.Reply, Note: strings.TrimSpace(r.Note)})
		}
		js, err := json.Marshal(replies)
		if err != nil {
			return nil, fmt.Errorf("encoding review replies: %w", err)
		}
		start.Replies = string(js)
	}
	return start, nil
}

// checkRepliesAgainst refuses replies that do not answer prev's open review
// round.
func checkRepliesAgainst(replies []reviewReply, prev *db.OwnerAsk, row *db.SpecReview) error {
	switch {
	case prev == nil || row == nil || row.Loop == "":
		return &ValidationError{Msg: "review_replies: previous_ask_id is not a spec review in the author loop — file without review_replies"}
	case row.Loop == "owner":
		return &ValidationError{Msg: errOwnerHasReview}
	case prev.Status != "open":
		return &ValidationError{Msg: fmt.Sprintf("review_replies: ask %d is %s", prev.ID, prev.Status)}
	}
	items, err := decodeAuthorItems(row)
	if err != nil {
		return err
	}
	open := map[string]bool{}
	for _, it := range items {
		open[it.Key] = true
	}
	for _, r := range replies {
		if key := strings.TrimSpace(r.Key); !open[key] {
			return &ValidationError{Msg: fmt.Sprintf("review_replies: %s is not a finding of ask %d's review — read them with get_spec_review %d", key, prev.ID, prev.ID)}
		}
	}
	return nil
}

func decodeAuthorItems(row *db.SpecReview) ([]specreview.AuthorItem, error) {
	items := []specreview.AuthorItem{}
	if row.OpenItems == "" {
		return items, nil
	}
	if err := json.Unmarshal([]byte(row.OpenItems), &items); err != nil {
		return nil, fmt.Errorf("spec review %d open items: %w", row.AskID, err)
	}
	return items, nil
}

// revealFailedLoop makes a loop ask whose reviewer did not start visible:
// round 1 has nothing to carry, a later round carries the previous round's
// items as unsettled. A failure is appended to the result.
func revealFailedLoop(d *db.DB, askID int64, round int, result string) string {
	now := time.Now()
	var err error
	if round <= 1 {
		_, err = d.RevealSpecLoop(askID, specreview.EndReviewerFailed, "", now)
	} else {
		err = specreview.Reveal(d, askID, specreview.EndReviewerFailed, now)
	}
	if err != nil {
		return result + " (not shown to the owner yet: " + err.Error() + ")"
	}
	return result
}

// specLoopOf is an ask's loop state for get_ask/list_asks: author, owner or
// "" (not a spec/plan review, no review row, or not a loop review).
func specLoopOf(d *db.DB, a *db.OwnerAsk) (string, error) {
	if a.DocType != string(specreview.Spec) && a.DocType != string(specreview.Plan) {
		return "", nil
	}
	row, err := d.GetSpecReview(a.ID)
	if errors.Is(err, db.ErrSpecReviewNotFound) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return row.Loop, nil
}

// ---- get_spec_review ---------------------------------------------------

type getSpecReviewArgs struct {
	AskID int64 `json:"ask_id" jsonschema:"the review ask the findings line names"`
}

type specReviewView struct {
	AskID     int64                   `json:"ask_id"`
	Round     int                     `json:"round"`
	MaxRounds int                     `json:"max_rounds"`
	Loop      string                  `json:"loop"`
	Status    string                  `json:"status"`
	Reason    string                  `json:"reason"`
	Items     []specreview.AuthorItem `json:"items"`
	Hint      string                  `json:"hint"`
}

// NewGetSpecReview reads the spec review of one of this workbench's review
// asks: in the author loop, a finished round's findings for the author.
func NewGetSpecReview() *Tool {
	return &Tool{
		Name: "get_spec_review",
		Description: "Read the independent review of a spec or plan ask you filed. While the reviewer and you are " +
			"looping (loop author), a finished round's findings are in items: fix each in the document or disagree " +
			"with a reason, then file the next round with ask_owner (previous_ask_id and review_replies).",
		InputSchema: mustSchema[getSpecReviewArgs]("get_spec_review"),
		Access:      AccessRead,
		Surfaces:    workbenchSurfaces,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a getSpecReviewArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			p, err := workbenchOf(ctx, d, call.Binding)
			if err != nil {
				return nil, err
			}
			if _, err := askInWorkbench(d, p.ID, a.AskID); err != nil {
				return nil, err
			}
			row, err := d.GetSpecReview(a.AskID)
			if errors.Is(err, db.ErrSpecReviewNotFound) {
				return nil, &ValidationError{Msg: fmt.Sprintf("ask %d has no spec review", a.AskID), Err: err}
			}
			if err != nil {
				return nil, err
			}
			return specReviewOf(row)
		},
	}
}

func specReviewOf(row *db.SpecReview) (*specReviewView, error) {
	v := &specReviewView{AskID: row.AskID, Round: row.Round, MaxRounds: specreview.MaxLoopRounds,
		Loop: row.Loop, Status: row.Status, Reason: row.Reason, Items: []specreview.AuthorItem{}}
	switch {
	case row.Loop == "author" && row.Status == "done":
		items, err := decodeAuthorItems(row)
		if err != nil {
			return nil, err
		}
		v.Items = items
		v.Hint = fmt.Sprintf("Fix each item in the document or disagree with a reason, then file the next round: "+
			"ask_owner with previous_ask_id %d and one review_replies entry per item.", row.AskID)
	case row.Loop == "author" && (row.Status == "queued" || row.Status == "running"):
		v.Hint = fmt.Sprintf("The reviewer is still on round %d; wait for the findings line.", row.Round)
	case row.Loop == "author":
		v.Hint = "The reviewer did not finish; the ask goes to the owner — wait for their answer."
	default:
		v.Hint = fmt.Sprintf("The owner has this review; wait for their answer (get_ask %d).", row.AskID)
	}
	return v, nil
}
