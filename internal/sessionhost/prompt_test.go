package sessionhost

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

// Go twins of the owner-input PROJ-12 guards in WatchtowerDesktop's
// TerminalCenterTests / TerminalCenterSubmitTests / AgentInputProfileTests:
// the same meaning, read off the host's prompt state instead of
// TerminalCenter's sets. The delivery outcomes they lead to are Task 13's
// (Deliver); these assert the state Deliver decides on.

// hostSession returns the server's session of (row, "r1").
func hostSession(t *testing.T, srv *Server, row int64) *session {
	t.Helper()
	sess := srv.lookup(row, "r1")
	if sess == nil {
		t.Fatalf("no session row %d", row)
	}
	return sess
}

// typeChunks sends each chunk as one Input frame, then waits until the host
// has handled them (a List answered after them on the same connection).
func (c *client) typeChunks(chunks ...[]byte) {
	c.t.Helper()
	for _, chunk := range chunks {
		c.send(Input, chunk)
	}
	c.expectNoError()
}

func (s *session) pause(begin bool) (ownerReturned bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if begin {
		s.prompt.beginPause()
		return false
	}
	return s.prompt.endPause()
}

func TestClaudeProfileBytesUnchanged(t *testing.T) {
	p := ProfileFor("claude")
	if !bytes.Equal(p.Submit, []byte{0x0D}) || p.Newline != nil ||
		p.PasteSettle != 150*time.Millisecond || p.SubmitSettle != 500*time.Millisecond {
		t.Fatalf("claude profile = %+v", p)
	}
	// A session with no agent (a shell) or an unknown one is typed into as
	// Claude Code's, as TerminalCenter.inputProfile does.
	for _, agent := range []string{"", "other"} {
		got := ProfileFor(agent)
		if !bytes.Equal(got.Submit, p.Submit) || got.Newline != nil || got.PasteSettle != p.PasteSettle ||
			got.SubmitSettle != p.SubmitSettle {
			t.Fatalf("ProfileFor(%q) = %+v, want claude's", agent, got)
		}
	}
}

func TestCodexProfileIsCRSubmitWithCtrlJNewline(t *testing.T) {
	p := ProfileFor("codex")
	if !bytes.Equal(p.Submit, []byte{0x0D}) || !bytes.Equal(p.Newline, []byte{0x0A}) ||
		p.PasteSettle != 150*time.Millisecond || p.SubmitSettle != 500*time.Millisecond {
		t.Fatalf("codex profile = %+v", p)
	}
}

// Twin of testIsSubmitPerProfile: only a plain CR submits, under every
// profile; `\` then Return stays a draft in Codex too (fail safe).
func TestIsSubmitPerProfile(t *testing.T) {
	drafts := []struct {
		name string
		b    []byte
	}{
		{"Ctrl+J", []byte("a\n")},
		{"Option+Return", []byte("a\x1b\r")},
		{"kitty Shift+Return", []byte("a\x1b[13;2u")},
		{"backslash Return", []byte("a\\\r")},
		{"text", []byte("a")},
		{"Ctrl+C", []byte{0x03}},
		{"empty", nil},
	}
	for _, agent := range []string{"claude", "codex"} {
		p := ProfileFor(agent)
		for _, d := range drafts {
			if IsSubmit(d.b, false, p) {
				t.Errorf("%s: %s read as a submit", agent, d.name)
			}
		}
		if !IsSubmit([]byte("a\r"), false, p) || !IsSubmit([]byte{0x0D}, false, p) {
			t.Errorf("%s: a plain Return is not a submit", agent)
		}
		if IsSubmit([]byte{0x0D}, true, p) {
			t.Errorf("%s: a Return after a `\\` typed earlier read as a submit", agent)
		}
	}
}

// Twin of testClaudeCodeLineBreakKeysLeaveTheDraft: Claude Code's line-break
// keys end with CR or LF but do not submit — the owner's multi-line draft
// stays, so the prompt holds text.
func TestClaudeCodeLineBreakKeysLeaveTheDraft(t *testing.T) {
	path, srv := startHost(t, Options{})
	shapes := []struct {
		name   string
		chunks []string
	}{
		{"Option+Return (ESC CR)", []string{"fix", "\x1b\r"}},
		{"backslash, then Return", []string{"fix\\", "\r"}},
		{"backslash and Return in one chunk", []string{"fix\\\r"}},
		{"Ctrl+J (LF)", []string{"fix", "\n"}},
		{"Shift+Return, kitty protocol", []string{"fix", "\x1b[13;2u"}},
		{"Shift+Return, modifyOtherKeys", []string{"fix", "\x1b[27;2;13~"}},
		{"a pasted backslash, then Return", []string{"\x1b[200~fix\\\x1b[201~", "\r"}},
		{"backslash, cursor keys, then Return", []string{"fix\\", "\x1b[D\x1b[C", "\r"}},
		{"backslash, an SS3 cursor key and Return in one chunk", []string{"fix\\\x1bOD\r"}},
	}
	for i, shape := range shapes {
		row := int64(i + 1)
		a := dial(t, path)
		a.launchAgent(row, "claude", `exec cat`)
		a.typeChunks(byteChunks(shape.chunks)...)
		if !hostSession(t, srv, row).promptHoldsText() {
			t.Errorf("%s: no draft", shape.name)
		}
	}

	row := int64(len(shapes) + 1)
	a := dial(t, path)
	a.launchAgent(row, "claude", `exec cat`)
	sess := hostSession(t, srv, row)
	a.typeChunks([]byte("fix\r"))
	if sess.promptHoldsText() {
		t.Fatal("a plain Return submits the draft")
	}
	a.typeChunks([]byte("a\\"), []byte("b"), []byte{0x0D})
	if sess.promptHoldsText() {
		t.Fatal("a backslash followed by text no longer escapes the Return")
	}
}

func byteChunks(chunks []string) [][]byte {
	out := make([][]byte, len(chunks))
	for i, c := range chunks {
		out[i] = []byte(c)
	}
	return out
}

// Twin of testTheOwnersReturnDuringThePauseSkipsOurs: the owner's own
// submitting Return during a line's pause sent it (with whatever they typed
// before), so Deliver must send no second Return; text typed after it is the
// owner's own draft. A Return into a permission dialog sends nothing of the
// line, and `\` then Return is a line break, not a submit.
func TestTheOwnersReturnDuringThePauseSkipsOurs(t *testing.T) {
	path, srv := startHost(t, Options{})
	a := dial(t, path)
	a.launchAgent(1, "claude", `exec cat`)
	sess := hostSession(t, srv, 1)

	for _, c := range []struct {
		name  string
		input string
	}{{"a bare Return", "\r"}, {"text, then Return", "and this\r"}} {
		sess.pause(true)
		a.typeChunks([]byte(c.input))
		if !sess.pause(false) {
			t.Errorf("%s: the owner's Return during the pause not seen", c.name)
		}
		if sess.promptHoldsText() {
			t.Errorf("%s: the prompt still holds text after the owner sent it", c.name)
		}
	}

	sess.pause(true)
	a.typeChunks([]byte{0x0D}, []byte("next"))
	if !sess.pause(false) {
		t.Fatal("the owner's Return then text: the Return not seen")
	}
	if !sess.promptHoldsText() {
		t.Fatal("the text typed after the Return is a draft a later Return of ours would submit")
	}
	a.typeChunks([]byte{0x0D})

	b := dial(t, path)
	b.send(PromptHint, PromptHintMsg{Row: 1, Run: "r1", Dialog: true})
	b.expectNoError()
	sess.pause(true)
	a.typeChunks([]byte{0x0D})
	b.send(PromptHint, PromptHintMsg{Row: 1, Run: "r1", Dialog: false})
	b.expectNoError()
	if sess.pause(false) {
		t.Fatal("a Return into the permission dialog counted as sending the line")
	}

	sess.pause(true)
	a.typeChunks([]byte("a\\\r"))
	if sess.pause(false) {
		t.Fatal("`\\` then Return counted as sending the line")
	}
	if !sess.promptHoldsText() {
		t.Fatal("`\\` then Return left no draft")
	}
}

// Twin of the dialog half of testOverTheOwnersDraftSubmitPromptOnlyPastes and
// testALineLeftWithoutItsReturnKeepsTheNextFromSubmittingIt: keys answering a
// permission dialog (PromptHint{Dialog: true}) change nothing — no draft from
// a key, no submit from a Return.
func TestADialogKeyIsNoDraft(t *testing.T) {
	path, srv := startHost(t, Options{})
	a := dial(t, path)
	a.launchAgent(1, "claude", `exec cat`)
	sess := hostSession(t, srv, 1)
	b := dial(t, path)
	hint := func(dialog bool) {
		b.send(PromptHint, PromptHintMsg{Row: 1, Run: "r1", Dialog: dialog})
		b.expectNoError()
	}

	hint(true)
	a.typeChunks([]byte("2"))
	if sess.promptHoldsText() {
		t.Fatal("a key into the permission dialog left a draft")
	}
	a.typeChunks([]byte("\\"))
	hint(false)
	a.typeChunks([]byte{0x0D})
	if sess.promptHoldsText() {
		t.Fatal("a `\\` into the dialog turned the owner's next Return into a line break")
	}

	a.typeChunks([]byte("half"))
	hint(true)
	a.typeChunks([]byte{0x0D})
	if !sess.promptHoldsText() {
		t.Fatal("the dialog's Return emptied the prompt")
	}
	hint(false)
	a.typeChunks([]byte{0x0D})
	if sess.promptHoldsText() {
		t.Fatal("the owner's Return did not empty the prompt")
	}
}

// Twin of testCodexDraftTrackingUsesCodexNewline: the owner's Ctrl+J line
// break in Codex's composer is a draft; their plain Return submits it.
func TestCodexDraftTrackingUsesCodexNewline(t *testing.T) {
	path, srv := startHost(t, Options{})
	a := dial(t, path)
	a.launchAgent(1, "codex", `exec cat`)
	sess := hostSession(t, srv, 1)

	a.typeChunks([]byte("half\n"))
	if !sess.promptHoldsText() {
		t.Fatal("Codex's Ctrl+J left no draft")
	}
	a.typeChunks([]byte{0x0D})
	if sess.promptHoldsText() {
		t.Fatal("a plain Return did not submit Codex's draft")
	}
}

// Review Focus 1: the owner types in one client's pane (attached, Input
// frames) while another client — the hub — is about to deliver into the
// same session without attaching. The host sees the draft, so Task 13's
// Deliver leaves the line typed (or held for a phone line).
func TestDeliverWhileOwnerTypesInAnotherClientLeavesTyped(t *testing.T) {
	path, srv := startHost(t, Options{})
	a := dial(t, path)
	info := a.launchAgent(1, "claude", `exec cat`)
	a.typeChunks([]byte("a"), []byte("b"), []byte("c"))

	b := dial(t, path)
	b.expectNoError()
	if !hostSession(t, srv, 1).promptHoldsText() {
		t.Fatal("the owner's draft typed in client A is not seen by a delivery from client B")
	}
	// B never attached: A keeps its pane and its echo.
	if got := b.list(); len(got) != 1 || got[0].Launch != info.Launch {
		t.Fatalf("list = %+v", got)
	}
	a.send(Input, []byte("z"))
	a.outputUntil(func(s string) bool { return strings.Contains(s, "z") })
}

// Every InputTo is fed into the prompt state like Input (the brief: every
// byte of input passes through the host); a key there is a draft too.
func TestInputToFeedsThePromptState(t *testing.T) {
	path, srv := startHost(t, Options{})
	a := dial(t, path)
	info := a.launchAgent(1, "claude", `exec cat`)
	sess := hostSession(t, srv, 1)
	b := dial(t, path)

	b.send(InputTo, InputToReq{Row: 1, Run: "r1", Launch: info.Launch, Data: []byte("x")})
	b.expectNoError()
	if !sess.promptHoldsText() {
		t.Fatal("InputTo text left no draft")
	}
	b.send(InputTo, InputToReq{Row: 1, Run: "r1", Launch: info.Launch, Data: []byte{0x0D}})
	b.expectNoError()
	if sess.promptHoldsText() {
		t.Fatal("InputTo's Return did not empty the prompt")
	}
}

// A line left typed (Task 13: pasted, no Return) holds the prompt until the
// owner's submitting Return; other keys and a dialog's Return keep it.
func TestALineLeftTypedHoldsUntilTheOwnersReturn(t *testing.T) {
	var p promptState
	prof := ProfileFor("claude")
	p.leaveTyped()
	if !p.holdsText() || !p.leftTyped {
		t.Fatal("a line left typed does not hold the prompt")
	}
	p.ownerInput([]byte("x"), prof)
	p.dialog = true
	p.ownerInput([]byte{0x0D}, prof)
	p.dialog = false
	if !p.holdsText() || !p.leftTyped {
		t.Fatal("a key or a dialog's Return cleared the line left typed")
	}
	p.ownerInput([]byte{0x0D}, prof)
	if p.holdsText() || p.leftTyped {
		t.Fatal("the owner's Return did not send the line left typed")
	}

	// A pending Return holds the prompt for its pause only.
	p.beginPause()
	if !p.holdsText() {
		t.Fatal("a line in its pause does not hold the prompt")
	}
	if p.endPause() || p.holdsText() || p.pendingReturn || p.ownerReturnInPause {
		t.Fatal("the pause did not end clean")
	}
}

// The host reads bracketed-paste mode (2004) from the output it rings.
func TestBracketedPasteModeFollowsTheOutput(t *testing.T) {
	path, srv := startHost(t, Options{})
	a := dial(t, path)
	a.launchAgent(1, "claude", `printf 'ready\033[?2004h'; read x; printf 'off\033[?2004l'; exec cat`)
	sess := hostSession(t, srv, 1)
	a.outputUntil(func(s string) bool { return strings.Contains(s, "\x1b[?2004h") })
	if !sess.bracketedPaste() {
		t.Fatal("bracketed paste on in the output, off in the host")
	}
	a.send(Input, []byte("go\r"))
	a.outputUntil(func(s string) bool { return strings.Contains(s, "\x1b[?2004l") })
	if sess.bracketedPaste() {
		t.Fatal("bracketed paste off in the output, on in the host")
	}
}
