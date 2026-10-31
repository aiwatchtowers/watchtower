// Package termqr prints a QR code in terminal block characters, for
// `watchtower hub pair` on a headless host (go-hub spec §10).
//
// Each printed line carries two module rows (half blocks), one column per
// module, quiet zone included. A dark module prints as the terminal's
// background, so the code reads on a dark terminal.
package termqr

import (
	"fmt"
	"io"

	"github.com/skip2/go-qrcode"
)

// Render writes text's QR code (error correction Low) to w and returns its
// width in columns. Nothing is written when the text does not fit a QR code.
func Render(w io.Writer, text string) (width int, err error) {
	q, err := qrcode.New(text, qrcode.Low)
	if err != nil {
		return 0, fmt.Errorf("termqr: %w", err)
	}
	width = len(q.Bitmap())
	if _, err := io.WriteString(w, q.ToSmallString(false)); err != nil {
		return 0, fmt.Errorf("termqr: write: %w", err)
	}
	return width, nil
}

// Width is the number of columns Render needs for text, quiet zone included.
func Width(text string) (int, error) {
	q, err := qrcode.New(text, qrcode.Low)
	if err != nil {
		return 0, fmt.Errorf("termqr: %w", err)
	}
	return len(q.Bitmap()), nil
}
