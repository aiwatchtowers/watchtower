// Package termqr prints a QR code in terminal block characters, for
// `watchtower hub pair` on a headless host (go-hub spec §10).
//
// Each printed line carries two module rows (half blocks), one column per
// module, quiet zone included. The colours are explicit — black modules on
// a bright white background, quiet zone included (owner ruling, ask #883) —
// so the code reads the same on a light and on a dark terminal.
package termqr

import (
	"fmt"
	"io"
	"strings"

	"github.com/skip2/go-qrcode"
)

// lineStart and lineEnd wrap every printed line: black foreground on a
// bright white background, then a reset, so the colours never reach the
// text after the code.
const (
	lineStart = "\x1b[30;107m"
	lineEnd   = "\x1b[0m"
)

// Render writes text's QR code (error correction Low) to w and returns its
// width in columns. Nothing is written when the text does not fit a QR code.
func Render(w io.Writer, text string) (width int, err error) {
	bits, err := bitmap(text)
	if err != nil {
		return 0, err
	}
	var b strings.Builder
	for y := 0; y < len(bits); y += 2 {
		b.WriteString(lineStart)
		for x := range bits[y] {
			top := bits[y][x]
			bottom := y+1 < len(bits) && bits[y+1][x] // past the last row: background
			switch {
			case top && bottom:
				b.WriteString("█")
			case top:
				b.WriteString("▀")
			case bottom:
				b.WriteString("▄")
			default:
				b.WriteString(" ")
			}
		}
		b.WriteString(lineEnd + "\n")
	}
	if _, err := io.WriteString(w, b.String()); err != nil {
		return 0, fmt.Errorf("termqr: write: %w", err)
	}
	return len(bits), nil
}

// Width is the number of columns Render needs for text, quiet zone included.
func Width(text string) (int, error) {
	bits, err := bitmap(text)
	if err != nil {
		return 0, err
	}
	return len(bits), nil
}

// bitmap is text's module matrix, true = dark, quiet zone included.
func bitmap(text string) ([][]bool, error) {
	q, err := qrcode.New(text, qrcode.Low)
	if err != nil {
		return nil, fmt.Errorf("termqr: %w", err)
	}
	return q.Bitmap(), nil
}
