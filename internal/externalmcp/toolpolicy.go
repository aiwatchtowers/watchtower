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
// "query" (arbitrary SQL can write) and "fetch" (an arbitrary-URL GET is an
// exfiltration channel, the reason WebFetch is hidden) are left out on purpose.
var readVerbs = map[string]bool{
	"get": true, "list": true, "search": true, "read": true,
	"find": true, "describe": true, "lookup": true,
}

// mutatingWords anywhere after the leading verb deny an unannotated tool:
// compound names such as getOrCreateIssue or read_and_delete_message write,
// and a tool that fetches a caller-chosen address is no plain read.
var mutatingWords = map[string]bool{
	"or": true, "and": true, "create": true, "update": true, "upsert": true, "delete": true,
	"remove": true, "set": true, "send": true, "post": true, "put": true, "add": true,
	"insert": true, "write": true, "edit": true, "modify": true, "patch": true,
	"upload": true, "move": true, "copy": true, "archive": true, "close": true,
	"merge": true, "assign": true, "transition": true, "publish": true, "submit": true,
	"execute": true, "exec": true, "run": true, "invoke": true, "approve": true,
	"reject": true, "cancel": true, "clear": true, "reset": true, "save": true,
	"store": true, "mark": true, "toggle": true, "enable": true, "disable": true,
	"start": true, "stop": true, "kill": true, "drop": true, "purge": true,
	// Fetching an arbitrary address is the exfiltration channel WebFetch is
	// hidden for, whatever the verb (read_url, get_webpage).
	"url": true, "uri": true, "webpage": true, "http": true, "https": true,
}

// IsReadOnly is QC-02's default policy for one tool: a tool its server
// annotated is read-only only when it declares readOnlyHint (the MCP spec's
// default is false, so an annotated tool without the hint is a write); a tool
// with no annotations at all is read-only only when its name starts with a
// read verb (get/list/search/read/find/describe/lookup) and no later word is a
// conjunction or a write verb.
func IsReadOnly(t db.ExternalTool) bool {
	if t.Annotated {
		return t.ReadOnlyHint
	}
	words := nameWords(t.Name)
	if len(words) == 0 || !readVerbs[words[0]] {
		return false
	}
	for _, w := range words[1:] {
		if mutatingWords[w] {
			return false
		}
	}
	return true
}

// nameWords splits a tool name into lowercased words at '_', '-', '.', ' '
// and inner capitals ("getJiraIssue" → get, jira, issue).
func nameWords(name string) []string {
	var words []string
	start := 0
	flush := func(end int) {
		if end > start {
			words = append(words, strings.ToLower(name[start:end]))
		}
	}
	for i, r := range name {
		switch {
		case r == '_' || r == '-' || r == '.' || r == ' ':
			flush(i)
			start = i + 1
		case i > start && unicode.IsUpper(r):
			flush(i)
			start = i
		}
	}
	flush(len(name))
	return words
}

// IsAnnotatedWrite reports whether t's server declared it a write: it sent
// annotations without readOnlyHint (the MCP default is false, and a
// destructiveHint is meaningful only then). No owner allow list can admit
// such a tool (QC-02 stays read-only until external writes get an Approve).
func IsAnnotatedWrite(t db.ExternalTool) bool {
	return t.Annotated && !t.ReadOnlyHint
}

// ResolveTools splits c's listed tools into the names the chat may call and
// the names it must not (QC-02). With the owner's explicit allow list, a
// listed tool it names is allowed unless the listing shows it annotated as a
// write; a name the listing lacks is never allowed (only a listing shows
// whether a tool is a write). Otherwise only IsReadOnly tools are. A
// connection whose tools were never listed allows none (fail closed).
func ResolveTools(c db.ExternalConnection) (allowed, denied []string) {
	if !c.ToolsListed {
		return nil, nil
	}
	ok := IsReadOnly
	if c.AllowTools != nil {
		named := make(map[string]bool, len(c.AllowTools))
		for _, name := range c.AllowTools {
			named[name] = true
		}
		ok = func(t db.ExternalTool) bool { return named[t.Name] && !IsAnnotatedWrite(t) }
	}
	for _, t := range c.Tools {
		if ok(t) {
			allowed = append(allowed, t.Name)
		} else {
			denied = append(denied, t.Name)
		}
	}
	return allowed, denied
}
