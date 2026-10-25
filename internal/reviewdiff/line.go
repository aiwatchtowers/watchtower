package reviewdiff

import "fmt"

// DeliveryLine is the one line the Desktop types into the round's session
// after Send, through PROJ-12's gates (spec §9) — the Go side of the Swift
// ReviewDeliveryLine, pinned by testdata/lines. No owner or agent text is in it.
func DeliveryLine(roundID int64, comments int) string {
	return fmt.Sprintf("Review round #%d sent (%s) — read it with get_review %d using the watchtower-workbench skill.",
		roundID, CommentCount(comments), roundID)
}

// ApprovedLine is the line typed into the session after Approve: the round
// closed with no changes requested. Pinned by testdata/lines (kind "approved").
func ApprovedLine(roundID int64) string {
	return fmt.Sprintf("Review round #%d approved — the owner approved this branch; finish it the way your methodology says (read get_review %d using the watchtower-workbench skill).",
		roundID, roundID)
}

// CommentCount renders "1 comment", "N comments" (the delivery line and the brief).
func CommentCount(n int) string {
	if n == 1 {
		return "1 comment"
	}
	return fmt.Sprintf("%d comments", n)
}
