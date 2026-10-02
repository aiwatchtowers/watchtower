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
		// destructiveHint wins over a contradictory readOnlyHint.
		{db.ExternalTool{Name: "getIssue", Annotated: true, ReadOnlyHint: true, DestructiveHint: true}, false},
		// No annotations: the leading word decides.
		{db.ExternalTool{Name: "getJiraIssue"}, true},
		{db.ExternalTool{Name: "list_pages"}, true},
		{db.ExternalTool{Name: "search-docs"}, true},
		{db.ExternalTool{Name: "ReadFile"}, true},
		{db.ExternalTool{Name: "lookupUser"}, true},
		{db.ExternalTool{Name: "getJIRAIssue"}, true},
		// query (arbitrary SQL) and fetch (arbitrary URL) are not known read-only.
		{db.ExternalTool{Name: "query"}, false},
		{db.ExternalTool{Name: "fetch_url"}, false},
		// Compound names with a conjunction or a write verb are writes.
		{db.ExternalTool{Name: "getOrCreateIssue"}, false},
		{db.ExternalTool{Name: "find_or_create_contact"}, false},
		{db.ExternalTool{Name: "read_and_delete_message"}, false},
		{db.ExternalTool{Name: "list-and-archive"}, false},
		{db.ExternalTool{Name: "getAndSetFlag"}, false},
		// Fetching a caller-chosen address is not a plain read.
		{db.ExternalTool{Name: "read_url"}, false},
		{db.ExternalTool{Name: "getWebpage"}, false},
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
	t.Run("never listed allows nothing even with an explicit list", func(t *testing.T) {
		allowed, _ := ResolveTools(db.ExternalConnection{AllowTools: []string{"createIssue"}})
		assert.Empty(t, allowed, "only a listing shows whether a named tool is a write")
	})
	t.Run("explicit list replaces the default", func(t *testing.T) {
		allowed, denied := ResolveTools(db.ExternalConnection{Tools: listed, ToolsListed: true,
			AllowTools: []string{"createIssue"}})
		assert.Equal(t, []string{"createIssue"}, allowed, "an unannotated tool the owner names is allowed")
		assert.Equal(t, []string{"getIssue", "deleteIssue", "summarize"}, denied)
	})
	t.Run("explicit list never admits a name the listing lacks", func(t *testing.T) {
		allowed, _ := ResolveTools(db.ExternalConnection{Tools: listed, ToolsListed: true,
			AllowTools: []string{"getIssue", "delete_page"}})
		assert.Equal(t, []string{"getIssue"}, allowed, "an unlisted name could be a write the listing never saw")
	})
	t.Run("explicit list never admits an annotated write", func(t *testing.T) {
		allowed, denied := ResolveTools(db.ExternalConnection{Tools: listed, ToolsListed: true,
			AllowTools: []string{"deleteIssue", "summarize"}})
		assert.Equal(t, []string{"summarize"}, allowed)
		assert.Equal(t, []string{"getIssue", "createIssue", "deleteIssue"}, denied)
	})
	t.Run("explicit empty list allows nothing", func(t *testing.T) {
		allowed, denied := ResolveTools(db.ExternalConnection{Tools: listed, ToolsListed: true, AllowTools: []string{}})
		assert.Empty(t, allowed)
		assert.Len(t, denied, 4)
	})
}
