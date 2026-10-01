package confluence

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

type cdataPiece struct {
	raw, body string
	isCDATA   bool
}

func collectCDATA(xhtml string) []cdataPiece {
	var out []cdataPiece
	SplitCDATA(xhtml, func(raw, body string, isCDATA bool) {
		out = append(out, cdataPiece{raw, body, isCDATA})
	})
	return out
}

func TestSplitCDATA(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want []cdataPiece
	}{
		{"no cdata", "<p>a</p>", []cdataPiece{{"<p>a</p>", "<p>a</p>", false}}},
		{"empty", "", nil},
		{"one section", "<b><![CDATA[x > y]]></b>", []cdataPiece{
			{"<b>", "<b>", false},
			{"<![CDATA[x > y]]>", "x > y", true},
			{"</b>", "</b>", false},
		}},
		{"split close delimiter", "<![CDATA[a]]]]><![CDATA[>b]]>", []cdataPiece{
			{"<![CDATA[a]]]]>", "a]]", true},
			{"<![CDATA[>b]]>", ">b", true},
		}},
		{"unterminated", "x<![CDATA[tail > more", []cdataPiece{
			{"x", "x", false},
			{"<![CDATA[tail > more", "tail > more", true},
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := collectCDATA(tc.in)
			assert.Equal(t, tc.want, got)
			var b strings.Builder
			for _, p := range got {
				b.WriteString(p.raw)
			}
			assert.Equal(t, tc.in, b.String(), "raw pieces must partition the input")
		})
	}
}
