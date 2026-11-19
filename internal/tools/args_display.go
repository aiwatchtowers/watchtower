package tools

import (
	"bytes"
	"encoding/json"
	"strings"

	"github.com/rivo/uniseg"
)

// MaxArgsDisplay is the most characters (grapheme clusters) ArgsDisplay keeps.
const MaxArgsDisplay = 4000

// ArgsDisplay is an action's args as an approval card off the Mac shows them
// (the phone's chat and Inbox, mobile Inbox spec §12.1): indented JSON (the
// stored text when it is not JSON), cut at MaxArgsDisplay characters with a
// trailing "…", and whether the text is whole. The approval hash is over the
// stored bytes (ArgsSHA256), never this text.
func ArgsDisplay(argsJSON string) (string, bool) {
	var buf bytes.Buffer
	text := argsJSON
	if json.Indent(&buf, []byte(argsJSON), "", "  ") == nil {
		text = buf.String()
	}
	if uniseg.GraphemeClusterCount(text) <= MaxArgsDisplay {
		return text, true
	}
	var b strings.Builder
	g := uniseg.NewGraphemes(text)
	for n := 0; n < MaxArgsDisplay-1 && g.Next(); n++ {
		b.WriteString(g.Str())
	}
	b.WriteString("…")
	return b.String(), false
}
