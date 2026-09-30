package confluenceedit

import (
	"errors"
	"os"
	"testing"
)

// FuzzApply: Apply never panics (carry (e)), every refusal is an
// *EditError, and a successful replace_text changes bytes only inside the
// span of one editable unit — every other byte of the page survives.
func FuzzApply(f *testing.F) {
	rich, err := os.ReadFile("testdata/rich.xhtml")
	if err == nil {
		f.Add(string(rich), "on budget", "under **budget**", "Scope", "- a\n  - b\n\n| x |\n| --- |\n| y |")
		f.Add(string(rich), "Ann Lee", "⟦2:x⟧", "Release plan", "```\n]]>\n```\n\n⟦7:table 2x2⟧")
	}
	f.Add(sectionsSrc, "m1", "[a](b) _c_ `d`", "Mid", "### Deep\n\n⟦2:emoticon smile⟧")
	f.Add(`<p>a <!-- c --> b ⟦1:x⟧</p><h1>H</h1>`, "a", "b", "H", "x")
	f.Add("<p>a <code>x\x005\x00y</code> b</p>", "b", "c", "", "")
	f.Add("<p><ac:emoticon ac:name=\"s\"/> <code>x\x001\x00y</code> <code>`\x00</code> b</p><h2>H</h2>", "b", "c\x00\x01", "H", "`\x001\x00`")
	f.Add(`<p>call __init__ and 2**10 vs 3**4 [1](2) here</p>`, "here", "[x](javascript:y)", "", "")
	f.Fuzz(func(t *testing.T, src, old, repl, heading, body string) {
		d, err := Parse(src)
		if err != nil {
			return
		}
		out, _, err := Apply(d, []Edit{text(old, repl)})
		checkEditError(t, err)
		if err == nil {
			checkWithinOneUnit(t, d, out)
		}
		_, _, err = Apply(d, []Edit{text(old, repl), sectionEdit(heading, body), text(repl, old), sectionEdit(heading, repl)})
		checkEditError(t, err)
		if d.Render() != src {
			t.Fatal("Apply modified its Doc")
		}
	})
}

func checkEditError(t *testing.T, err error) {
	t.Helper()
	var ee *EditError
	if err != nil && !errors.As(err, &ee) {
		t.Fatalf("error is not an *EditError: %v", err)
	}
}

func checkWithinOneUnit(t *testing.T, d *Doc, out string) {
	t.Helper()
	pre, suf := commonAffixes(d.src, out)
	for _, u := range d.units {
		if u.start <= pre && len(d.src)-suf <= u.end {
			return
		}
	}
	t.Fatalf("diff [%d,%d) is not inside one unit\nsrc: %q\nout: %q", pre, len(d.src)-suf, d.src, out)
}
