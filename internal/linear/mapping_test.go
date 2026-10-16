package linear

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestStatusCategory(t *testing.T) {
	for in, want := range map[string]string{
		"triage": "todo", "backlog": "todo", "unstarted": "todo",
		"started": "in_progress", "completed": "done", "canceled": "done", "something_new": "todo",
	} {
		assert.Equal(t, want, StatusCategory(in), in)
	}
}

func TestMentionedUserIDs(t *testing.T) {
	doc := `{"type":"doc","content":[{"type":"paragraph","content":[
	  {"type":"text","text":"hi "},
	  {"type":"suggestion_userMentions","attrs":{"id":"user-1","label":"Ann"}},
	  {"type":"text","text":" and "},
	  {"type":"suggestion_userMentions","attrs":{"id":"user-2","label":"Bo"}},
	  {"type":"suggestion_userMentions","attrs":{"id":"user-1","label":"Ann"}}]}]}`
	assert.Equal(t, []string{"user-1", "user-2"}, MentionedUserIDs(doc))
}

func TestMentionedUserIDs_Malformed(t *testing.T) {
	assert.Equal(t, []string{}, MentionedUserIDs(""))
	assert.Equal(t, []string{}, MentionedUserIDs("{not json"))
	assert.Equal(t, []string{}, MentionedUserIDs(`{"type":"doc"}`))
}
