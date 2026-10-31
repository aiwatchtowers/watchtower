package termqr_test

import (
	"bytes"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/skip2/go-qrcode"
	"github.com/stretchr/testify/require"

	"watchtower/internal/termqr"
)

// The colour codes around every line, pinned: black modules on a bright
// white background, then a reset (ask #883).
const (
	lineStart = "\x1b[30;107m"
	lineEnd   = "\x1b[0m"
)

// decode reads Render's lines back into a module matrix (true = dark
// module), through the colour codes. Each line holds two module rows: the
// top and the bottom half of every cell, the foreground (black) being dark:
// "█" = both dark, " " = both light, "▀" = top dark, "▄" = bottom dark. A
// QR has an odd number of rows, so the last line's bottom half is padding.
func decode(t *testing.T, lines []string, rows int) [][]bool {
	t.Helper()
	var m [][]bool
	for _, line := range lines {
		require.True(t, strings.HasPrefix(line, lineStart) && strings.HasSuffix(line, lineEnd),
			"every line is wrapped in the colour codes: %q", line)
		var top, bottom []bool
		for _, r := range strings.TrimSuffix(strings.TrimPrefix(line, lineStart), lineEnd) {
			switch r {
			case '█':
				top, bottom = append(top, true), append(bottom, true)
			case ' ':
				top, bottom = append(top, false), append(bottom, false)
			case '▀':
				top, bottom = append(top, true), append(bottom, false)
			case '▄':
				top, bottom = append(top, false), append(bottom, true)
			default:
				t.Fatalf("unexpected rune %q in the QR output", r)
			}
		}
		m = append(m, top, bottom)
	}
	require.Len(t, m, rows+1, "the last line's bottom half is padding")
	for _, dark := range m[rows] {
		require.False(t, dark, "the padding is background, never a dark half")
	}
	return m[:rows]
}

func TestRenderMatchesTheBitmap(t *testing.T) {
	for _, text := range []string{
		"https://example.com/link#AAAA",
		"https://example.com/link#" + strings.Repeat("B", 300),
	} {
		q, err := qrcode.New(text, qrcode.Low)
		require.NoError(t, err)
		want := q.Bitmap()
		require.Equal(t, 1, len(want)%2, "a QR symbol has an odd number of rows")

		var buf bytes.Buffer
		width, err := termqr.Render(&buf, text)
		require.NoError(t, err)
		require.Equal(t, len(want[0]), width)

		lines := strings.Split(strings.TrimSuffix(buf.String(), "\n"), "\n")
		require.Len(t, lines, (len(want)+1)/2, "two module rows per line")
		for _, line := range lines {
			cells := strings.TrimSuffix(strings.TrimPrefix(line, lineStart), lineEnd)
			require.Equal(t, width, len([]rune(cells)), "every line is the QR's width")
		}
		require.Equal(t, want, decode(t, lines, len(want)))
		// The quiet zone is light (background): the first line is blank.
		require.Equal(t, strings.Repeat(" ", width), strings.TrimSuffix(strings.TrimPrefix(lines[0], lineStart), lineEnd))

		w, err := termqr.Width(text)
		require.NoError(t, err)
		require.Equal(t, width, w)
	}
}

func TestRenderRefusesTextTooLongForAQR(t *testing.T) {
	var buf bytes.Buffer
	_, err := termqr.Render(&buf, strings.Repeat("x", 4000))
	require.Error(t, err)
	require.Zero(t, buf.Len(), "nothing is written on an error")
	_, err = termqr.Width(strings.Repeat("x", 4000))
	require.Error(t, err)
}

// TestWidthOfAV4HeadlessLink pins the number the narrow-window hint prints
// for a headless hub's link ("Widen this window to at least N columns …"):
// the shared fixture's v4_headless URL, quiet zone included.
func TestWidthOfAV4HeadlessLink(t *testing.T) {
	raw, err := os.ReadFile("../../WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json")
	require.NoError(t, err)
	var f struct {
		LinkPayload []struct {
			Name string `json:"name"`
			URL  string `json:"url"`
		} `json:"link_payload"`
	}
	require.NoError(t, json.Unmarshal(raw, &f))
	var url string
	for _, c := range f.LinkPayload {
		if c.Name == "v4_headless" {
			url = c.URL
		}
	}
	require.NotEmpty(t, url, "fixture case v4_headless")

	w, err := termqr.Width(url)
	require.NoError(t, err)
	// 606 bytes → version 17 (85 modules) + a 4-module quiet zone each side.
	require.Equal(t, 93, w)
}
