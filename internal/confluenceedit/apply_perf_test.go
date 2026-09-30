package confluenceedit

import (
	"strings"
	"testing"
	"time"
)

// TestApplyAdversarialInlineStaysFast: 60k-character paragraphs and
// section bodies of unmatched delimiters, brackets, backtick runs and
// unbalanced hrefs go through the inline parser, the markdown parser and
// Text without a quadratic blow-up (the worst case measured ~0.15s when
// this was written; the quadratic paths it guards took 0.5-1s+ at this
// size and grow 4x per doubling).
func TestApplyAdversarialInlineStaysFast(t *testing.T) {
	n := 60000
	start := time.Now()
	for _, pat := range []string{
		strings.Repeat("[", n/2) + "](x)",
		"[" + strings.Repeat("[a", n/2) + "](x)",
		strings.Repeat("**a ", n/4),
		strings.Repeat("_a ", n/3),
		strings.Repeat("~~", n/2),
		strings.Repeat("` ``", n/4),
		strings.Repeat("`", n),
		"[a](" + strings.Repeat("(", n),
		strings.Repeat("[a](", n/4),
		strings.Repeat("**_~~", n/5) + "x" + strings.Repeat("~~_**", n/5),
	} {
		src := "<p>zz " + textEscaper.Replace(pat) + "</p>"
		if _, _, err := Apply(mustParse(t, src), []Edit{text("zz", "yy")}); err != nil {
			t.Fatal(err)
		}
		body := pat + "\n\n- " + pat + "\n\n| " + pat + " |"
		if _, _, err := Apply(mustParse(t, "<h1>H</h1><p>q</p>"), []Edit{sectionEdit("H", body)}); err != nil {
			t.Fatal(err)
		}
	}
	if d := time.Since(start); d > 8*time.Second {
		t.Fatalf("adversarial inputs took %v", d)
	}
}
