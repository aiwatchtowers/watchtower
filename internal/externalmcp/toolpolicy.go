package externalmcp

import (
	"strings"
	"unicode"

	"watchtower/internal/db"
)

// readVerbs are the leading name words the QC-02 fallback heuristic treats as
// read-only for a tool its server did not annotate. Deliberately short: a
// verb missing here only means an unannotated read tool stays denied until
// the owner allows it (`connections tools <id> --allow`), while a write verb
// slipping in would let the chat mutate a third-party system unapproved.
var readVerbs = map[string]bool{
	"get": true, "list": true, "search": true, "read": true, "fetch": true,
	"query": true, "find": true, "describe": true, "lookup": true,
}

// IsReadOnly is QC-02's default policy for one tool: a tool its server
// annotated is read-only only when it declares readOnlyHint (the MCP spec's
// default is false, so an annotated tool without the hint is a write); a tool
// with no annotations at all falls back to its name's leading word being a
// read verb (get/list/search/read/fetch/query/find/describe/lookup).
func IsReadOnly(t db.ExternalTool) bool {
	if t.Annotated {
		return t.ReadOnlyHint
	}
	return readVerbs[leadingWord(t.Name)]
}

// leadingWord returns name's first word, lowercased: the run before the first
// '_', '-', '.', ' ' or inner capital ("getJiraIssue" → "get",
// "list_pages" → "list"). A name with no separator is one word.
func leadingWord(name string) string {
	for i, r := range name {
		if r == '_' || r == '-' || r == '.' || r == ' ' || (i > 0 && unicode.IsUpper(r)) {
			return strings.ToLower(name[:i])
		}
	}
	return strings.ToLower(name)
}

// ResolveTools splits c's tools into the names the chat may call and the
// listed names it must not (QC-02). With the owner's explicit allow list,
// exactly those names are allowed. Otherwise only IsReadOnly tools are, and a
// connection whose tools were never listed allows none (fail closed).
func ResolveTools(c db.ExternalConnection) (allowed, denied []string) {
	if c.AllowTools != nil {
		allow := make(map[string]bool, len(c.AllowTools))
		for _, name := range c.AllowTools {
			allow[name] = true
		}
		allowed = append(allowed, c.AllowTools...)
		for _, t := range c.Tools {
			if !allow[t.Name] {
				denied = append(denied, t.Name)
			}
		}
		return allowed, denied
	}
	for _, t := range c.Tools {
		if IsReadOnly(t) {
			allowed = append(allowed, t.Name)
		} else {
			denied = append(denied, t.Name)
		}
	}
	return allowed, denied
}
