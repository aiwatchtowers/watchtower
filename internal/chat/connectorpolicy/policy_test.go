package connectorpolicy

import (
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"testing"
)

const (
	testWorkDir    = "/work"
	testPublishDir = "/work/publish/7"
	ownURL         = "https://claude.ai/artifact/own-1"
	foreignURL     = "https://claude.ai/artifact/other-2"
	docsServer     = "claude.ai Claude Docs"
	gmailServer    = "claude.ai Gmail"
	ownDoc         = "own-doc"
	// ownC is a container naming the doc this session created.
	ownC = `"container":{"kind":"project","id":"own-doc"}`
)

// fakeCatalog maps "token/tool" to annotations; a server with any entry, or
// a bare "token" key, is a listed connector.
type fakeCatalog map[string]Annotations

func (f fakeCatalog) Connector(serverToken string) bool {
	for k := range f {
		if k == serverToken || strings.HasPrefix(k, serverToken+"/") {
			return true
		}
	}
	return false
}

func (f fakeCatalog) Lookup(serverToken, tool string) (Annotations, bool) {
	a, ok := f[serverToken+"/"+tool]
	return a, ok
}

func ptr(b bool) *bool { return &b }

// lexicalCheck stands in for the publish dir's Check: relative paths resolve
// against the work dir, the result must sit strictly inside the publish dir.
func lexicalCheck(p string) error {
	if !filepath.IsAbs(p) {
		p = filepath.Join(testWorkDir, p)
	}
	p = filepath.Clean(p)
	if !strings.HasPrefix(p, testPublishDir+"/") {
		return errors.New("outside")
	}
	if strings.HasPrefix(p, testPublishDir+"/linked/") {
		return errors.New("symlink") // stands in for a link planted inside the dir
	}
	return nil
}

func testPolicy() Policy {
	return Policy{
		Catalog: fakeCatalog{
			"claude_ai_Gmail/search":       {ReadOnly: ptr(true)},
			"claude_ai_Gmail/list_labels":  {ReadOnly: ptr(true), Destructive: ptr(false)},
			"claude_ai_Gmail/send":         {ReadOnly: ptr(false)},
			"claude_ai_Gmail/archive":      {ReadOnly: ptr(true), Destructive: ptr(true)},
			"claude_ai_Gmail/draft":        {},
			"claude_ai_Claude_Docs/delete": {ReadOnly: ptr(true)},
			"claude_ai_Claude_Docs/batch":  {ReadOnly: ptr(false)},
			"claude_ai_Caf_Notes":          {}, // listed, its tools not yet known
			"claude_ai_Slack":              {},
		},
		Disabled:    map[string]bool{"claude_ai_Slack": true},
		PathCheck:   lexicalCheck,
		PublishDir:  testPublishDir,
		OwnArtifact: func(url string) bool { return url == ownURL },
		OwnDoc:      func(id string) bool { return id == ownDoc },
	}
}

type decideCase struct {
	name    string
	call    Call
	want    Verdict
	reason  string // substring of Decision.Reason, when set
	updated string // expected UpdatedInput (JSON), when set
}

func gmail(tool string) Call {
	return Call{Tool: "mcp__claude_ai_Gmail__" + tool, Server: gmailServer, Input: json.RawMessage(`{}`)}
}

func docs(tool, input string) Call {
	return Call{Tool: "mcp__claude_ai_Claude_Docs__" + tool, Server: docsServer, Input: json.RawMessage(input)}
}

func builtin(tool, input string) Call {
	return Call{Tool: tool, Input: json.RawMessage(input)}
}

var decideCases = []decideCase{
	// Rule 1: file built-ins.
	{name: "write inside", call: builtin("Write", `{"file_path":"/work/publish/7/a.html","content":"x"}`), want: Allow},
	{name: "write nested new path", call: builtin("Write", `{"file_path":"/work/publish/7/sub/a.html"}`), want: Allow},
	{name: "write relative inside", call: builtin("Write", `{"file_path":"publish/7/a.html"}`), want: Allow},
	{name: "write relative outside", call: builtin("Write", `{"file_path":"a.html"}`), want: Deny,
		reason: "Write may only use files inside /work/publish/7"},
	{name: "write dotdot", call: builtin("Write", `{"file_path":"/work/publish/7/../x"}`), want: Deny},
	{name: "write the dir itself", call: builtin("Write", `{"file_path":"/work/publish/7"}`), want: Deny},
	{name: "write aliased key hides the real path", call: builtin("Write", `{"file_path":"/etc/x","FILE_PATH":"/work/publish/7/a"}`), want: Deny},
	{name: "write symlink climb", call: builtin("Write", `{"file_path":"/work/publish/7/link/../a"}`), want: Deny},
	{name: "write null path", call: builtin("Write", `{"file_path":null}`), want: Deny},
	{name: "write documents", call: builtin("Write", `{"file_path":"/Users/someone/Documents/x"}`), want: Deny},
	{name: "write no path", call: builtin("Write", `{"content":"x"}`), want: Deny},
	{name: "write bad json", call: builtin("Write", `[`), want: Deny},
	{name: "edit inside", call: builtin("Edit", `{"file_path":"/work/publish/7/a.html"}`), want: Allow},
	{name: "read outside", call: builtin("Read", `{"file_path":"/etc/hosts"}`), want: Deny,
		reason: "Read may only use files inside"},

	// Rule 2: Artifact.
	{name: "artifact no action publishes", call: builtin("Artifact", `{"file_path":"/work/publish/7/a.html"}`), want: Allow},
	{name: "artifact publish outside", call: builtin("Artifact", `{"action":"publish","file_path":"/tmp/a.html"}`), want: Deny,
		reason: "may only publish files inside"},
	{name: "artifact publish no source", call: builtin("Artifact", `{"action":"publish"}`), want: Allow},
	{name: "artifact file_paths one outside", call: builtin("Artifact",
		`{"action":"publish","url":"`+ownURL+`","asset":true,"file_paths":["/work/publish/7/a.png","/tmp/b.png"]}`), want: Deny},
	{name: "artifact files map inside", call: builtin("Artifact",
		`{"file_path":"/work/publish/7/a.html","files":{"s.css":"/work/publish/7/s.css","i.png":{"from":"publish/7/i.png","contentType":"image/png"},"copy.js":{"artifact":"`+foreignURL+`","path":"x.js"},"old.js":null}}`), want: Allow},
	{name: "artifact files map one outside", call: builtin("Artifact",
		`{"file_path":"/work/publish/7/a.html","files":{"s.css":"/work/publish/7/s.css","x.css":"/Users/someone/Desktop/x.css"}}`), want: Deny},
	{name: "artifact files map from outside", call: builtin("Artifact",
		`{"file_path":"/work/publish/7/a.html","files":{"x.css":{"from":"../x.css"}}}`), want: Deny},
	{name: "artifact files map odd value", call: builtin("Artifact",
		`{"file_path":"/work/publish/7/a.html","files":{"x.css":42}}`), want: Deny},
	{name: "artifact files list inside", call: builtin("Artifact",
		`{"file_path":"/work/publish/7/a.html","files":[{"path":"publish/7/s.css"}]}`), want: Allow},
	{name: "artifact files list of strings", call: builtin("Artifact",
		`{"file_path":"/work/publish/7/a.html","root":"/work/publish/7","files":["s.css","js/a.js"]}`), want: Allow},
	{name: "artifact files list string outside", call: builtin("Artifact",
		`{"file_path":"/work/publish/7/a.html","files":["/tmp/x.css"]}`), want: Deny},
	{name: "artifact files relative to root", call: builtin("Artifact",
		`{"file_path":"/work/publish/7/a.html","root":"/work/publish/7","files":{"s.css":"s.css"}}`), want: Allow},
	{name: "artifact root escape", call: builtin("Artifact",
		`{"file_path":"/work/publish/7/a.html","root":"/work/publish/7","files":{"s.css":"../../../x.css"}}`), want: Deny},
	{name: "artifact root climbs", call: builtin("Artifact",
		`{"file_path":"/work/publish/7/a.html","root":"/work/publish/7/link/..","files":{"s.css":"s.css"}}`), want: Deny},
	{name: "artifact root source climbs", call: builtin("Artifact",
		`{"file_path":"/work/publish/7/a.html","root":"/work/publish/7","files":{"s.css":"link/../s.css"}}`), want: Deny},
	{name: "artifact root outside", call: builtin("Artifact",
		`{"file_path":"/work/publish/7/a.html","root":"/work","files":{"s.css":"publish/7/s.css"}}`), want: Deny},
	{name: "artifact aliased file_path", call: builtin("Artifact", `{"file_path":"/tmp/a.html","FILE_PATH":"/work/publish/7/a.html"}`), want: Deny},
	{name: "artifact aliased files null", call: builtin("Artifact",
		`{"file_path":"/work/publish/7/a.html","files":{"x":"/tmp/x"},"Files":null}`), want: Deny},
	{name: "artifact aliased from", call: builtin("Artifact",
		`{"file_path":"/work/publish/7/a.html","files":{"x":{"from":"/tmp/x","FROM":"/work/publish/7/x"}}}`), want: Deny},
	{name: "artifact aliased list path", call: builtin("Artifact",
		`{"file_path":"/work/publish/7/a.html","files":[{"path":"/tmp/x","PATH":"/work/publish/7/x"}]}`), want: Deny},
	{name: "artifact aliased action", call: builtin("Artifact", `{"action":"delete","Action":"list","url":"`+ownURL+`"}`), want: Ask},
	{name: "artifact aliased url", call: builtin("Artifact", `{"file_path":"/work/publish/7/a.html","url":"`+foreignURL+`","URL":""}`), want: Ask},
	{name: "artifact aliased force", call: builtin("Artifact", `{"file_path":"/work/publish/7/a.html","force":true,"Force":false}`), want: Ask},
	{name: "artifact force not a bool", call: builtin("Artifact", `{"file_path":"/work/publish/7/a.html","force":"yes"}`), want: Deny},
	{name: "artifact publish pins", call: builtin("Artifact", `{"file_path":"/work/publish/7/a.html","pin":true}`), want: Ask,
		reason: "pins"},
	{name: "artifact own url", call: builtin("Artifact", `{"file_path":"/work/publish/7/a.html","url":"`+ownURL+`"}`), want: Allow},
	{name: "artifact foreign url", call: builtin("Artifact", `{"file_path":"/work/publish/7/a.html","url":"`+foreignURL+`"}`), want: Ask},
	{name: "artifact foreign url outside source", call: builtin("Artifact", `{"file_path":"/tmp/a.html","url":"`+foreignURL+`"}`), want: Deny},
	{name: "artifact force", call: builtin("Artifact", `{"file_path":"/work/publish/7/a.html","url":"`+ownURL+`","force":true}`), want: Ask},
	{name: "artifact read no out_dir", call: builtin("Artifact", `{"action":"read","url":"`+foreignURL+`","path":"x.js"}`), want: Allow,
		updated: `{"action":"read","out_dir":"/work/publish/7","path":"x.js","url":"` + foreignURL + `"}`},
	{name: "artifact read out_dir inside", call: builtin("Artifact", `{"action":"read","url":"`+foreignURL+`","out_dir":"/work/publish/7/r"}`), want: Allow},
	{name: "artifact read out_dir is the dir", call: builtin("Artifact", `{"action":"read","url":"`+foreignURL+`","out_dir":"/work/publish/7"}`), want: Allow},
	{name: "artifact read out_dir parent", call: builtin("Artifact", `{"action":"read","url":"`+foreignURL+`","out_dir":"/work/publish"}`), want: Deny},
	{name: "artifact read aliased out_dir", call: builtin("Artifact",
		`{"action":"read","out_dir":"/Users/someone/Downloads","Out_Dir":"/work/publish/7"}`), want: Deny},
	{name: "artifact read out_dir climbs", call: builtin("Artifact", `{"action":"read","url":"`+foreignURL+`","out_dir":"/work/publish/7/link/.."}`), want: Deny},
	{name: "artifact read path through a link", call: builtin("Artifact", `{"action":"read","url":"`+foreignURL+`","path":"linked/a.js"}`), want: Deny},
	{name: "artifact read nested path", call: builtin("Artifact", `{"action":"read","url":"`+foreignURL+`","paths":["a.js","js/b.js"]}`), want: Allow,
		updated: `{"action":"read","out_dir":"/work/publish/7","paths":["a.js","js/b.js"],"url":"` + foreignURL + `"}`},
	{name: "artifact read path climbs", call: builtin("Artifact", `{"action":"read","url":"`+foreignURL+`","path":"../../x"}`), want: Deny},
	{name: "artifact read paths absolute", call: builtin("Artifact", `{"action":"read","url":"`+foreignURL+`","paths":["a.js","/etc/x"]}`), want: Deny},
	{name: "artifact read out_dir outside", call: builtin("Artifact", `{"action":"read","url":"`+foreignURL+`","out_dir":"/Users/someone/Downloads"}`), want: Deny},
	{name: "artifact list", call: builtin("Artifact", `{"action":"list"}`), want: Allow},
	{name: "artifact open", call: builtin("Artifact", `{"action":"open","url":"`+ownURL+`"}`), want: Allow},
	{name: "artifact quickstart", call: builtin("Artifact", `{"action":"quickstart","intent":"other"}`), want: Allow},
	{name: "artifact delete", call: builtin("Artifact", `{"action":"delete","url":"`+ownURL+`"}`), want: Ask},
	{name: "artifact pin", call: builtin("Artifact", `{"action":"pin","url":"`+ownURL+`"}`), want: Ask},
	{name: "artifact unpin", call: builtin("Artifact", `{"action":"unpin","url":"`+ownURL+`"}`), want: Ask},
	{name: "artifact unknown action", call: builtin("Artifact", `{"action":"share"}`), want: Deny},
	{name: "artifact action not a string", call: builtin("Artifact", `{"action":1}`), want: Deny},
	{name: "artifact bad json", call: builtin("Artifact", `nope`), want: Deny},

	// Rule 3: not a claude.ai tool.
	{name: "hidden built-in", call: builtin("Bash", `{"command":"ls"}`), want: Deny, reason: "Bash is not available in this chat"},
	{name: "other mcp server", call: Call{Tool: "mcp__github__create_issue", Server: "github", Input: json.RawMessage(`{}`)}, want: Deny},
	{name: "collapsed connector token", call: Call{Tool: "mcp__claude_ai_Caf_Notes__read", Server: "claude.ai Café/Notes", Input: json.RawMessage(`{}`)}, want: Ask},
	{name: "local server spoofing a connector token", call: Call{Tool: "mcp__claude_ai_Claude_Docs__update", Server: "claude_ai_Claude_Docs", Input: json.RawMessage(`{}`)}, want: Deny},
	{name: "server name mismatch", call: Call{Tool: "mcp__claude_ai_Gmail__search", Server: "claude.ai Drive", Input: json.RawMessage(`{}`)}, want: Deny},
	{name: "connector without server", call: Call{Tool: "mcp__claude_ai_Gmail__search", Input: json.RawMessage(`{}`)}, want: Deny},
	{name: "built-in name with a server", call: Call{Tool: "Write", Server: gmailServer, Input: json.RawMessage(`{"file_path":"/work/publish/7/a"}`)}, want: Deny},

	// Rule 4: switched off.
	{name: "disabled server", call: Call{Tool: "mcp__claude_ai_Slack__search", Server: "claude.ai Slack", Input: json.RawMessage(`{}`)}, want: Deny,
		reason: "Slack is switched off in Settings → Profile → claude.ai tools"},

	// Rule 5: authentication tools.
	{name: "authenticate", call: gmail("authenticate"), want: Deny, reason: "connect Gmail on claude.ai first"},
	{name: "complete authentication", call: gmail("complete_authentication"), want: Deny},

	// Rule 6: overrides.
	{name: "docs create private", call: docs("create", `{"object":"utterance",`+ownC+`,"payload":{"value":{"body":"Done"}}}`), want: Allow},
	{name: "docs create mention other", call: docs("create",
		`{"object":"utterance","payload":{"value":{"blocks":{"m":{"type":"mention","user":"someone@example.com"}}}}}`), want: Ask,
		reason: "mentions someone"},
	{name: "docs update", call: docs("update",
		`{"ref":{"object":"node","id":"n1"},`+ownC+`,"payload":{"ops":[{"op":"delete","target":{"kind":"find","text":" draft"}}]}}`), want: Allow},
	{name: "docs mention without user", call: docs("create",
		`{"payload":{"value":{"blocks":{"m":{"type":"mention","id":"someone"}}}}}`), want: Ask},
	{name: "docs mention in attrs", call: docs("update",
		`{"payload":{"ops":[{"op":"insert","source":{"as":"blocks","from":{"content":[{"type":"mention","attrs":{"user":"u-other"}}]}}}]}}`), want: Ask},
	{name: "docs mention aliased user", call: docs("create",
		`{"payload":{"value":{"blocks":{"m":{"type":"mention","user":"me","User":"someone@example.com"}}}}}`), want: Ask},
	{name: "docs mention of a tab", call: docs("update",
		`{`+ownC+`,"payload":{"ops":[{"op":"insert","with":{"blocks":{"t":{"type":"mention","ref":"file/f2"}}}}]}}`), want: Allow},
	{name: "docs mention nested user with a ref", call: docs("create",
		`{"payload":{"value":{"blocks":{"m":{"type":"mention","attrs":{"user":"u-other"},"Ref":"x"}}}}}`), want: Ask},
	{name: "docs mention aliased ref", call: docs("create",
		`{"payload":{"value":{"blocks":{"m":{"type":"mention","Ref":"file/f2"}}}}}`), want: Ask},
	{name: "docs string payload", call: docs("update", `{"ref":{"object":"node","id":"n1"},"payload":"{\"op\":\"remove\"}"}`), want: Ask},
	{name: "docs null input", call: docs("update", `null`), want: Ask},
	{name: "docs update patch remove", call: docs("update",
		`{"ref":{"object":"project","id":"p1"},"payload":{"kind":"patch","patch":[{"op":"remove","path":["tabs","f2"]}]}}`), want: Ask},
	{name: "docs batch birth with me mention", call: docs("batch",
		`{"container":{"kind":"project","create":{"name":"Plan","doc":{"blocks":{"me":{"type":"mention","user":"me"}},"markdown":"# Plan"}}},"batch":[]}`), want: Allow},
	{name: "docs batch member delete", call: docs("batch",
		`{"container":{"kind":"project","id":"p1"},"batch":[{"verb":"delete","ref":{"object":"file","id":"f1"}}]}`), want: Ask,
		reason: "deletes"},
	{name: "docs batch share field", call: docs("batch", `{"container":{"kind":"project","id":"p1"},"batch":[],"Sharing":{"link":true}}`), want: Ask,
		reason: "who can see"},
	{name: "docs batch bad json", call: docs("batch", `{`), want: Ask},
	// Rule 6, OwnDoc: only a doc this session created is free.
	{name: "docs update of a foreign doc", call: docs("update",
		`{"ref":{"object":"node","id":"n1"},"container":{"kind":"project","id":"other-doc"},"payload":{"ops":[]}}`), want: Ask,
		reason: "did not create"},
	{name: "docs update naming no doc", call: docs("update", `{"ref":{"object":"node","id":"n1"},"payload":{"ops":[]}}`), want: Ask},
	{name: "docs rename own doc", call: docs("update", `{"ref":{"object":"project","id":"own-doc"},"payload":{"kind":"patch","patch":[]}}`), want: Allow},
	{name: "docs rename foreign doc", call: docs("update", `{"ref":{"object":"project","id":"other-doc"},"payload":{"kind":"patch","patch":[]}}`), want: Ask},
	{name: "docs comment on a foreign doc", call: docs("create",
		`{"object":"utterance","container":{"kind":"project","id":"other-doc"},"payload":{"value":{"body":"Hi"}}}`), want: Ask},
	{name: "docs create with a birth container", call: docs("create",
		`{"object":"utterance","container":{"kind":"project","create":{"name":"x"}},"payload":{"value":{"body":"Hi"}}}`), want: Ask},
	{name: "docs batch on own doc", call: docs("batch", `{`+ownC+`,"batch":[{"verb":"update","ref":{"object":"node","id":"n1"},"payload":{"ops":[]}}]}`), want: Allow},
	{name: "docs batch on a foreign doc", call: docs("batch", `{"container":{"kind":"project","id":"other-doc"},"batch":[]}`), want: Ask},
	{name: "docs batch member names a foreign doc", call: docs("batch",
		`{`+ownC+`,"batch":[{"verb":"update","ref":{"object":"project","id":"other-doc"},"payload":{"kind":"patch","patch":[]}}]}`), want: Ask},
	{name: "docs birth member names the doc being born", call: docs("batch",
		`{"container":{"kind":"project","create":{"name":"Plan","doc":{"markdown":"# Plan"}}},"batch":[{"verb":"update","ref":{"object":"project","id":"$lid:p"},"payload":{"kind":"patch","patch":[]}}]}`), want: Allow},
	{name: "docs container aliased key", call: docs("update",
		`{`+ownC+`,"Container":{"kind":"project","id":"other-doc"},"ref":{"object":"node","id":"n1"},"payload":{"ops":[]}}`), want: Ask},
	{name: "docs container id aliased", call: docs("update",
		`{"container":{"kind":"project","id":"own-doc","ID":"other-doc"},"ref":{"object":"node","id":"n1"},"payload":{"ops":[]}}`), want: Ask},
	{name: "docs member ref aliased", call: docs("batch",
		`{`+ownC+`,"batch":[{"verb":"update","REF":{"object":"project","id":"other-doc"},"payload":{}}]}`), want: Ask},
	{name: "docs own container, foreign doc ref", call: docs("update",
		`{`+ownC+`,"ref":{"object":"project","id":"other-doc"},"payload":{"kind":"patch","patch":[]}}`), want: Ask},
	{name: "docs own container, tab by global id", call: docs("update",
		`{`+ownC+`,"ref":{"object":"file","id":"foreign-tab"},"payload":{"kind":"patch","patch":[]}}`), want: Ask},
	{name: "docs own container, comment by global id", call: docs("update",
		`{`+ownC+`,"ref":{"object":"utterance","id":"c1"},"payload":{"value":{"body":"x"}}}`), want: Ask},
	{name: "docs member tab by global id", call: docs("batch",
		`{`+ownC+`,"batch":[{"verb":"update","ref":{"object":"file","id":"foreign-tab"},"payload":{}}]}`), want: Ask},
	{name: "docs birth member tab being born", call: docs("batch",
		`{"container":{"kind":"project","create":{"name":"Plan"}},"batch":[{"verb":"update","ref":{"object":"file","id":"$lid:f2"},"payload":{}}]}`), want: Allow},
	{name: "docs member doc ref in another case", call: docs("batch",
		`{`+ownC+`,"batch":[{"verb":"update","ref":{"object":"PROJECT","id":"other-doc"},"payload":{}}]}`), want: Ask},
	{name: "docs member object not a string", call: docs("batch",
		`{`+ownC+`,"batch":[{"verb":"update","ref":{"object":["project"],"id":"other-doc"},"payload":{}}]}`), want: Ask},
	{name: "docs member id not a string", call: docs("batch",
		`{`+ownC+`,"batch":[{"verb":"update","ref":{"object":"node","id":7},"payload":{}}]}`), want: Ask},
	{name: "docs member with its own container", call: docs("batch",
		`{`+ownC+`,"batch":[{"verb":"update","container":{"kind":"project","id":"other-doc"},"ref":{"object":"node","id":"n1"},"payload":{}}]}`), want: Ask},
	{name: "docs foreign doc named in the payload", call: docs("create",
		`{"object":"utterance",`+ownC+`,"payload":{"value":{"body":"x","parent":{"object":"Project","id":"other-doc"}}}}`), want: Ask},
	{name: "docs comment parent node in own doc", call: docs("create",
		`{"object":"utterance",`+ownC+`,"payload":{"value":{"body":"x","parent":{"object":"node","id":"n1","anchor":{"kind":"find","text":"Plan"}}}}}`), want: Allow},
	{name: "docs reply to a comment by global id", call: docs("create",
		`{"object":"utterance",`+ownC+`,"payload":{"value":{"body":"x","parent":{"object":"utterance","id":"foreign-c"}}}}`), want: Ask},
	{name: "docs comment on a tab by global id", call: docs("create",
		`{"object":"utterance",`+ownC+`,"payload":{"value":{"body":"x","parent":{"object":"file","id":"foreign-tab"}}}}`), want: Ask},
	{name: "docs parent as a bare id", call: docs("create",
		`{"object":"utterance",`+ownC+`,"payload":{"value":{"body":"x","parent":"foreign-root"}}}`), want: Ask},
	{name: "docs answering a thread", call: docs("update",
		`{`+ownC+`,"ref":{"object":"node","id":"n1"},"answering":"foreign-root","payload":{"ops":[]}}`), want: Ask},
	{name: "docs nested doc ref with a create key", call: docs("batch",
		`{`+ownC+`,"batch":[{"verb":"update","ref":{"object":"node","id":"n1"},"payload":{"x":{"object":"project","id":"other-doc","create":{}}}}]}`), want: Ask},
	{name: "docs nested doc ref with an aliased id", call: docs("batch",
		`{`+ownC+`,"batch":[{"verb":"update","ref":{"object":"node","id":"n1"},"payload":{"x":{"object":"project","id":"own-doc","ID":"other-doc"}}}]}`), want: Ask},
	{name: "docs birth with an enum member", call: docs("batch",
		`{"container":{"kind":"project","create":{"name":"Plan"}},"batch":[{"$lid":"s","verb":"create","object":"enum","payload":{"value":{"name":"Status"}}}]}`), want: Allow},
	{name: "docs parent object without a type", call: docs("create",
		`{"object":"utterance",`+ownC+`,"payload":{"value":{"body":"x","parent":{"id":"foreign-c"}}}}`), want: Ask},
	{name: "docs answering object without a type", call: docs("update",
		`{`+ownC+`,"ref":{"object":"node","id":"n1"},"answering":{"id":"foreign-root"},"payload":{"ops":[]}}`), want: Ask},
	{name: "docs member type with a foreign id", call: docs("batch",
		`{`+ownC+`,"batch":[{"verb":"update","object":"file","id":"foreign-tab","payload":{}}]}`), want: Ask},
	{name: "docs create type with a foreign id", call: docs("create",
		`{"object":"file",`+ownC+`,"id":"foreign-tab","payload":{}}`), want: Ask},
	{name: "docs birth member names a newborn enum", call: docs("batch",
		`{"container":{"kind":"project","create":{"name":"Plan"}},"batch":[{"verb":"update","ref":{"object":"node","id":"$lid:n"},"payload":{"x":{"object":"enum","id":"$lid:e"}}}]}`), want: Allow},
	{name: "docs answering with a node type", call: docs("update",
		`{`+ownC+`,"ref":{"object":"node","id":"n1"},"answering":{"object":"node","id":"foreign-root"},"payload":{"ops":[]}}`), want: Ask},
	{name: "docs container not an object", call: docs("update", `{"container":"own-doc","ref":{"object":"node","id":"n1"},"payload":{"ops":[]}}`), want: Ask},
	{name: "docs read", call: docs("read", `{"ref":{"object":"project","id":"p1"}}`), want: Allow},
	{name: "docs query", call: docs("query", `{}`), want: Allow},
	{name: "docs guide", call: docs("guide", `{"items":["topic.index"]}`), want: Allow},
	{name: "docs delete despite readOnly annotation", call: docs("delete", `{"ref":{"object":"project","id":"p1"}}`), want: Ask},

	// Rule 7: read-only annotation.
	{name: "readonly", call: gmail("search"), want: Allow},
	{name: "readonly not destructive", call: gmail("list_labels"), want: Allow},

	// Rule 8: everything else asks.
	{name: "write annotation", call: gmail("send"), want: Ask},
	{name: "readonly but destructive", call: gmail("archive"), want: Ask},
	{name: "no annotation", call: gmail("draft"), want: Ask},
	{name: "unknown to the catalog", call: gmail("forward"), want: Ask},
	{name: "unlisted docs tool", call: docs("export", `{}`), want: Ask},
}

func TestPolicy_Decide(t *testing.T) {
	p := testPolicy()
	for _, tc := range decideCases {
		t.Run(tc.name, func(t *testing.T) {
			got := p.Decide(tc.call)
			if got.Verdict != tc.want {
				t.Fatalf("verdict = %v (%q), want %v", got.Verdict, got.Reason, tc.want)
			}
			if got.Reason == "" {
				t.Errorf("empty reason")
			}
			if tc.reason != "" && !strings.Contains(got.Reason, tc.reason) {
				t.Errorf("reason = %q, want it to contain %q", got.Reason, tc.reason)
			}
			if tc.updated != "" {
				if string(got.UpdatedInput) != tc.updated {
					t.Errorf("UpdatedInput = %s, want %s", got.UpdatedInput, tc.updated)
				}
			} else if got.UpdatedInput != nil {
				t.Errorf("UpdatedInput = %s, want nil", got.UpdatedInput)
			}
		})
	}
}

// TestPolicy_FailsClosedWithoutSessionState: a Policy whose session parts are
// missing never allows a path, never updates a foreign artifact, and asks for
// every connector tool.
func TestPolicy_FailsClosedWithoutSessionState(t *testing.T) {
	var p Policy
	cases := []decideCase{
		{name: "write", call: builtin("Write", `{"file_path":"/work/publish/7/a"}`), want: Deny},
		{name: "artifact publish", call: builtin("Artifact", `{"file_path":"/work/publish/7/a"}`), want: Deny},
		{name: "artifact read", call: builtin("Artifact", `{"action":"read","url":"`+ownURL+`"}`), want: Deny},
		{name: "artifact update", call: builtin("Artifact", `{"url":"`+ownURL+`"}`), want: Ask},
		{name: "readonly connector", call: gmail("search"), want: Deny}, // no catalog lists no connector
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := p.Decide(tc.call); got.Verdict != tc.want {
				t.Fatalf("verdict = %v (%q), want %v", got.Verdict, got.Reason, tc.want)
			}
		})
	}
	var d Decision
	if d.Verdict != Deny {
		t.Fatalf("zero Verdict = %v, want deny", d.Verdict)
	}
}

func TestPolicy_UnknownCatalogEntryAsks(t *testing.T) {
	p := testPolicy()
	p.Catalog = fakeCatalog{"claude_ai_Gmail": {}}
	for _, c := range []Call{gmail("search"), gmail("send")} {
		if got := p.Decide(c); got.Verdict != Ask {
			t.Errorf("%s: verdict = %v, want ask", c.Tool, got.Verdict)
		}
	}
}

// A server the catalog does not list as an account connector is denied,
// whatever its name says (spec D1/D3); a nil catalog lists none.
func TestPolicy_UnlistedServerIsDenied(t *testing.T) {
	p := testPolicy()
	p.Catalog = fakeCatalog{"claude_ai_Gmail": {}}
	for _, c := range []Call{
		{Tool: "mcp__claude_ai_New_Server__fetch", Server: "claude.ai New Server", Input: json.RawMessage(`{}`)},
		docs("read", `{}`),
	} {
		got := p.Decide(c)
		if got.Verdict != Deny || !strings.Contains(got.Reason, "not one of this account's claude.ai connectors") {
			t.Errorf("%s: %v (%q), want deny", c.Tool, got.Verdict, got.Reason)
		}
	}
	p.Catalog = nil
	if got := p.Decide(gmail("search")); got.Verdict != Deny {
		t.Errorf("nil catalog: %v, want deny", got.Verdict)
	}
}

func TestPolicy_ReservedServerToken(t *testing.T) {
	for token, want := range map[string]bool{
		"claude_ai": true, "claude_ai_Gmail": true, "Claude_AI_Gmail": true, "CLAUDE_AI_x": true,
		"claude__ai_Gmail": true, "_claude_ai_Gmail": true, "claude_ai__Gmail__send": true,
		"claude_aix": false, "claude-ai_Gmail": false, "claudeai_Gmail": false, "my_claude_ai_x": false,
		"github": false, "": false,
	} {
		if got := ReservedServerToken(token); got != want {
			t.Errorf("ReservedServerToken(%q) = %v, want %v", token, got, want)
		}
	}
}

func TestPolicy_OverridesAreData(t *testing.T) {
	covered := map[string]bool{}
	for _, tc := range decideCases {
		if server, tool, ok := ParseToolName(tc.call.Tool); ok {
			covered[server+"/"+tool] = true
		}
	}
	seen := map[string]bool{}
	for _, row := range overrides {
		key := row.Server + "/" + row.Tool
		if strings.TrimSpace(row.Why) == "" {
			t.Errorf("%s: empty Why", key)
		}
		if seen[key] {
			t.Errorf("%s: duplicate row", key)
		}
		seen[key] = true
		if !covered[key] {
			t.Errorf("%s: no TestPolicy_Decide row", key)
		}
		if row.Verdict != Allow && row.Verdict != Ask {
			t.Errorf("%s: verdict %v; a Deny belongs in Disabled or rule 3", key, row.Verdict)
		}
		if row.CheckDocsWrite && row.Verdict != Allow {
			t.Errorf("%s: an input check only narrows an Allow", key)
		}
	}
}

func TestServerToken_Mapping(t *testing.T) {
	cases := map[string]string{
		"claude.ai Claude Docs":     "claude_ai_Claude_Docs",
		"claude.ai Google Calendar": "claude_ai_Google_Calendar",
		"claude.ai Atlassian-Rovo":  "claude_ai_Atlassian-Rovo",
		"claude.ai Café/Notes v2.1": "claude_ai_Caf_Notes_v2_1",
		"claude.ai Notes 📝":         "claude_ai_Notes",
		"local server/v2":           "local_server_v2",
		"local  server":             "local__server",
		"":                          "",
	}
	for in, want := range cases {
		if got := ServerToken(in); got != want {
			t.Errorf("ServerToken(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestParseToolName(t *testing.T) {
	good := []struct{ raw, server, tool string }{
		{"mcp__claude_ai_Gmail__send", "claude_ai_Gmail", "send"},
		{"mcp__claude_ai_Claude_Docs__batch", "claude_ai_Claude_Docs", "batch"},
		{"mcp__srv__tool__with__parts", "srv", "tool__with__parts"},
	}
	for _, g := range good {
		server, tool, ok := ParseToolName(g.raw)
		if !ok || server != g.server || tool != g.tool {
			t.Errorf("ParseToolName(%q) = %q, %q, %v; want %q, %q, true", g.raw, server, tool, ok, g.server, g.tool)
		}
	}
	for _, raw := range []string{"", "Write", "mcp__", "mcp__server", "mcp____tool", "mcp__server__", "MCP__a__b", "xmcp__a__b"} {
		if _, _, ok := ParseToolName(raw); ok {
			t.Errorf("ParseToolName(%q) ok = true, want false", raw)
		}
	}
}
