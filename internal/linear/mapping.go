package linear

import "encoding/json"

// StatusCategory maps a Linear workflow-state type onto the tracker-neutral
// status_category every Jira consumer already reads.
func StatusCategory(stateType string) string {
	switch stateType {
	case "started":
		return "in_progress"
	case "completed", "canceled":
		return "done"
	default: // triage, backlog, unstarted, and any type Linear adds later
		return "todo"
	}
}

type pmNode struct {
	Type    string         `json:"type"`
	Attrs   map[string]any `json:"attrs"`
	Content []pmNode       `json:"content"`
}

// mentionNodeType is the ProseMirror node Linear uses for a user mention in
// Comment.bodyData. Not confirmed against public docs (they do not describe
// bodyData); taken from the plan.
const mentionNodeType = "suggestion_userMentions"

// MentionedUserIDs returns the user ids mentioned in a comment's bodyData.
// A missing or malformed document yields no mentions, never an error: a
// comment must still be stored when its rich body cannot be read.
func MentionedUserIDs(bodyData string) []string {
	out := []string{}
	var root pmNode
	if bodyData == "" || json.Unmarshal([]byte(bodyData), &root) != nil {
		return out
	}
	seen := map[string]bool{}
	var walk func(n pmNode)
	walk = func(n pmNode) {
		if n.Type == mentionNodeType {
			if id, ok := n.Attrs["id"].(string); ok && id != "" && !seen[id] {
				seen[id] = true
				out = append(out, id)
			}
		}
		for _, c := range n.Content {
			walk(c)
		}
	}
	walk(root)
	return out
}
