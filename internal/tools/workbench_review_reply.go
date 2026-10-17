package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"

	"watchtower/internal/db"
)

const (
	maxReplyRunes  = 2000
	maxReasonRunes = 300
)

type replyReviewCommentArgs struct {
	CommentID int64  `json:"comment_id" jsonschema:"the id of the review comment, as get_review lists it"`
	Reply     string `json:"reply" jsonschema:"what you did about the comment, or why not (1-2000 characters)"`
	Resolved  bool   `json:"resolved" jsonschema:"true once the comment is fixed; the owner can reopen it. false only answers"`
	Reason    string `json:"reason" jsonschema:"one sentence: why you reply"`
}

func errCommentNotRepliable(id int64) error {
	return &ValidationError{Msg: fmt.Sprintf("comment %d is not in a sent review round of this workbench", id)}
}

// boundedText is s trimmed, 1..limit runes.
func boundedText(field, s string, limit int) (string, error) {
	s = strings.TrimSpace(s)
	switch {
	case s == "":
		return "", &ValidationError{Msg: field + ": required"}
	case utf8.RuneCountInString(s) > limit:
		return "", &ValidationError{Msg: fmt.Sprintf("%s: at most %d characters", field, limit)}
	}
	return s, nil
}

// NewReplyReviewComment is reply_review_comment: the agent answers one comment
// of a sent review round and may resolve it. Applied immediately and audited;
// the owner reopens a resolved comment from the reviewer.
func NewReplyReviewComment() *Tool {
	return &Tool{
		Name: "reply_review_comment",
		Description: "Answer one comment of a review round the owner sent (see get_review): say what you did, or why " +
			"not. Pass resolved true once it is fixed; the owner can reopen it. Applied immediately.",
		InputSchema: mustSchema[replyReviewCommentArgs]("reply_review_comment"),
		Access:      AccessWrite,
		Surfaces:    workbenchSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a replyReviewCommentArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if _, err := boundedText("reply", a.Reply, maxReplyRunes); err != nil {
				return err
			}
			_, err := boundedText("reason", a.Reason, maxReasonRunes)
			return err
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a replyReviewCommentArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			p, err := workbenchOf(ctx, d, b)
			if err != nil {
				return err
			}
			ok, err := d.ReviewCommentRepliable(p.ID, a.CommentID)
			if err != nil {
				return err
			}
			if !ok {
				return errCommentNotRepliable(a.CommentID)
			}
			return nil
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a replyReviewCommentArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding reply_review_comment args: %w", err)
			}
			p, err := workbenchOf(ctx, d, call.Binding)
			if err != nil {
				return nil, err
			}
			reply, err := boundedText("reply", a.Reply, maxReplyRunes)
			if err != nil {
				return nil, err
			}
			ok, err := d.ReplyReviewComment(p.ID, a.CommentID, reply, a.Resolved)
			if err != nil {
				return nil, err
			}
			if !ok {
				return nil, errCommentNotRepliable(a.CommentID)
			}
			return map[string]any{"comment_id": a.CommentID, "replied": true, "resolved": a.Resolved}, nil
		},
	}
}
