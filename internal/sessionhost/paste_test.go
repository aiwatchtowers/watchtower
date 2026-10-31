package sessionhost

import (
	"bytes"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// TestPasteFixture pins PasteText and PastePayload to testdata/paste_cases.json,
// which Swift's WorkbenchCommentPrompt.terminalPayload reads too
// (TerminalPasteFixtureTests): one cleaning rule on both sides.
func TestPasteFixture(t *testing.T) {
	b, err := os.ReadFile("testdata/paste_cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var fx struct {
		Cases []struct {
			Name           string `json:"name"`
			Line           string `json:"line"`
			KeepLineBreaks bool   `json:"keep_line_breaks"`
			KeepFormat     bool   `json:"keep_format"`
			Want           string `json:"want"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(b, &fx); err != nil {
		t.Fatal(err)
	}
	if len(fx.Cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range fx.Cases {
		got := PasteText(c.Line, c.KeepLineBreaks, c.KeepFormat)
		if got != c.Want {
			t.Errorf("%s: PasteText = %q, want %q", c.Name, got, c.Want)
		}
		payload := PastePayload(got)
		want := append(append([]byte{0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E}, c.Want...), 0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E)
		if !bytes.Equal(payload, want) {
			t.Errorf("%s: PastePayload = %q, want %q", c.Name, payload, want)
		}
	}
}

// Nothing inside the paste can end it early or submit: no ESC, and no CR or
// LF unless line breaks are kept (then LF only).
func TestPasteTextLeavesNoControlByte(t *testing.T) {
	line := "a\x1b[201~\r\n\x00\u0085 b"
	for _, keep := range []bool{false, true} {
		got := PasteText(line, keep, true)
		for _, r := range got {
			if r == '\n' && keep {
				continue
			}
			if r < 0x20 || r == 0x7F || (r >= 0x80 && r < 0xA0) {
				t.Fatalf("keep=%v: control %U in %q", keep, r, got)
			}
		}
		if strings.Contains(got, "\r") {
			t.Fatalf("keep=%v: CR in %q", keep, got)
		}
	}
}
