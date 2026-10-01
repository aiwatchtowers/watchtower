package externalmcp

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/db"
)

func TestIsReadOnly(t *testing.T) {
	for _, tc := range []struct {
		tool db.ExternalTool
		want bool
	}{
		// The server's annotation wins, both ways.
		{db.ExternalTool{Name: "createJiraIssue", Annotated: true, ReadOnlyHint: true}, true},
		{db.ExternalTool{Name: "getJiraIssue", Annotated: true}, false},
		// No annotations: the leading word decides.
		{db.ExternalTool{Name: "getJiraIssue"}, true},
		{db.ExternalTool{Name: "list_pages"}, true},
		{db.ExternalTool{Name: "search-docs"}, true},
		{db.ExternalTool{Name: "ReadFile"}, true},
		{db.ExternalTool{Name: "fetch"}, true},
		{db.ExternalTool{Name: "lookupUser"}, true},
		{db.ExternalTool{Name: "createJiraIssue"}, false},
		{db.ExternalTool{Name: "send_message"}, false},
		{db.ExternalTool{Name: "updateConfluencePage"}, false},
		{db.ExternalTool{Name: "getaccessibleresources"}, false}, // one word, not a read verb
		{db.ExternalTool{Name: "getter"}, false},
		{db.ExternalTool{Name: ""}, false},
	} {
		assert.Equal(t, tc.want, IsReadOnly(tc.tool), "%+v", tc.tool)
	}
}

func TestResolveTools(t *testing.T) {
	listed := []db.ExternalTool{
		{Name: "getIssue"},
		{Name: "createIssue"},
		{Name: "deleteIssue", Annotated: true},
		{Name: "summarize", Annotated: true, ReadOnlyHint: true},
	}

	t.Run("default policy allows only read-only tools", func(t *testing.T) {
		allowed, denied := ResolveTools(db.ExternalConnection{Tools: listed, ToolsListed: true})
		assert.Equal(t, []string{"getIssue", "summarize"}, allowed)
		assert.Equal(t, []string{"createIssue", "deleteIssue"}, denied)
	})
	t.Run("never listed allows nothing", func(t *testing.T) {
		allowed, denied := ResolveTools(db.ExternalConnection{})
		assert.Empty(t, allowed)
		assert.Empty(t, denied)
	})
	t.Run("explicit list replaces the default", func(t *testing.T) {
		allowed, denied := ResolveTools(db.ExternalConnection{Tools: listed, ToolsListed: true,
			AllowTools: []string{"createIssue"}})
		assert.Equal(t, []string{"createIssue"}, allowed)
		assert.Equal(t, []string{"getIssue", "deleteIssue", "summarize"}, denied)
	})
	t.Run("explicit empty list allows nothing", func(t *testing.T) {
		allowed, denied := ResolveTools(db.ExternalConnection{Tools: listed, ToolsListed: true, AllowTools: []string{}})
		assert.Empty(t, allowed)
		assert.Len(t, denied, 4)
	})
}
