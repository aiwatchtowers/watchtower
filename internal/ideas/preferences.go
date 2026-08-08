package ideas

import (
	"fmt"
	"strings"

	"watchtower/internal/db"
)

// buildPreferencesBlock renders the owner's recent idea verdicts — approved
// vs rejected — as few-shot examples for the consolidator prompt, so it can
// weigh what kind of material is worth surfacing versus too trivial to track
// (the buildSecretaryBrief precedent). Returns "" when there is no verdict
// history yet, so the assembled user message omits the section entirely.
func buildPreferencesBlock(database *db.DB) string {
	examples, err := database.ListIdeaVerdictExamples(20)
	if err != nil || len(examples) == 0 {
		return ""
	}

	// An explicit owner rating is the owner speaking directly, so its SIGN
	// decides the bucket outright; status is only consulted for an unrated
	// idea. Checking status first would file a thumbs-down on an active idea
	// under LIKED — teaching the consolidator the opposite of what the owner
	// said.
	var liked, disliked []db.Idea
	for _, idea := range examples {
		switch {
		case idea.OwnerRating > 0:
			liked = append(liked, idea)
		case idea.OwnerRating < 0:
			disliked = append(disliked, idea)
		case idea.Status == "active":
			liked = append(liked, idea)
		case idea.Status == "rejected" || idea.Status == "dropped":
			disliked = append(disliked, idea)
		}
	}
	if len(liked) == 0 && len(disliked) == 0 {
		return ""
	}

	var b strings.Builder
	if len(liked) > 0 {
		b.WriteString("LIKED/APPROVED:\n")
		writeVerdictList(&b, liked)
	}
	if len(disliked) > 0 {
		if b.Len() > 0 {
			b.WriteString("\n")
		}
		b.WriteString("DISLIKED/REJECTED:\n")
		writeVerdictList(&b, disliked)
	}
	return b.String()
}

// writeVerdictList appends one "- <title> (<rating_comment>)" line per idea,
// omitting the parenthetical when there is no comment.
func writeVerdictList(b *strings.Builder, ideas []db.Idea) {
	for _, idea := range ideas {
		fmt.Fprintf(b, "- %s", idea.Title)
		if idea.RatingComment != "" {
			fmt.Fprintf(b, " (%s)", idea.RatingComment)
		}
		b.WriteString("\n")
	}
}
