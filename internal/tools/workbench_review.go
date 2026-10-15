package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"watchtower/internal/db"
)

type getReviewArgs struct {
	RoundID int64 `json:"round_id" jsonschema:"the review round id from the Review round #N sent line or the brief"`
}

type reviewCommentView struct {
	ID          int64  `json:"id"`
	Path        string `json:"path,omitempty"`
	Side        string `json:"side"`
	StartLine   int    `json:"start_line"`
	EndLine     int    `json:"end_line"`
	Quote       string `json:"quote"`
	Lens        string `json:"lens,omitempty"`
	Body        string `json:"body"`
	CarriedFrom int64  `json:"carried_from,omitempty"`
}

type reviewView struct {
	RoundID   int64               `json:"round_id"`
	Status    string              `json:"status"`
	Folder    string              `json:"folder"`
	TreeSHA   string              `json:"tree_sha"`
	BaseLabel string              `json:"base_label"`
	Comments  []reviewCommentView `json:"comments"`
	Text      string              `json:"text"`
}

// NewGetReview is get_review: the agent reads a sent review round (spec §8.2); reading a
// sent round marks it delivered.
func NewGetReview() *Tool {
	return &Tool{
		Name: "get_review",
		Description: "Read a review round the owner sent from Watchtower's diff reviewer: every comment with its file, " +
			"lines, the quoted code and the owner's text. Answer each comment in your reply and fix the code; the " +
			"line 'Review round #N sent' or the session brief names the round.",
		InputSchema: mustSchema[getReviewArgs]("get_review"),
		Access:      AccessRead,
		Surfaces:    workbenchSurfaces,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a getReviewArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			p, err := workbenchOf(ctx, d, call.Binding)
			if err != nil {
				return nil, err
			}
			r, err := d.GetReviewRound(p.ID, a.RoundID)
			if err != nil {
				return nil, fmt.Errorf("review round %d is not on this workbench", a.RoundID)
			}
			if r.Status == "open" {
				return nil, fmt.Errorf("review round %d is still open: the owner has not sent it", a.RoundID)
			}
			if r.Status == "sent" {
				if _, err := d.MarkReviewRoundDelivered(p.ID, r.ID); err != nil {
					return nil, err
				}
				r.Status = "delivered"
			}
			cs, err := d.ReviewRoundComments(r.ID)
			if err != nil {
				return nil, err
			}
			v := reviewView{RoundID: r.ID, Status: r.Status, Folder: r.FolderRoot, TreeSHA: r.TreeSHA, BaseLabel: r.BaseLabel,
				Comments: []reviewCommentView{}}
			for _, c := range cs {
				if c.Status != "sent" {
					continue
				}
				v.Comments = append(v.Comments, reviewCommentView{ID: c.ID, Path: c.Path.String, Side: c.Side,
					StartLine: c.StartLine, EndLine: c.EndLine, Quote: c.Quote, Lens: c.Lens, Body: c.Body,
					CarriedFrom: c.CarriedFrom.Int64})
			}
			v.Text = reviewText(v)
			return v, nil
		},
	}
}

func reviewText(v reviewView) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Review round #%d — %d comment(s), folder %s\n", v.RoundID, len(v.Comments), v.Folder)
	for _, c := range v.Comments {
		where := "design"
		if c.Path != "" {
			where = fmt.Sprintf("%s:%d-%d", c.Path, c.StartLine, c.EndLine)
		}
		fmt.Fprintf(&b, "\n#%d %s\n", c.ID, where)
		for _, l := range strings.Split(strings.TrimRight(c.Quote, "\n"), "\n") {
			if l != "" {
				fmt.Fprintf(&b, "> %s\n", l)
			}
		}
		fmt.Fprintf(&b, "%s\n", c.Body)
	}
	return b.String()
}
