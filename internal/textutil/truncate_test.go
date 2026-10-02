package textutil

import (
	"testing"
	"unicode/utf8"
)

func TestTruncate(t *testing.T) {
	tests := []struct {
		name   string
		s      string
		n      int
		suffix string
		want   string
	}{
		{"fits", "hello", 10, "...", "hello"},
		{"exact", "hello", 5, "...", "hello"},
		{"ascii cut", "hello world", 5, "...", "hello..."},
		{"cyrillic fits by runes though not by bytes", "привет", 6, "...", "привет"},
		{"cyrillic cut on a rune boundary", "привет мир", 3, "...", "при..."},
		{"empty suffix", "привет", 2, "", "пр"},
		{"zero budget", "привет", 0, "...", "..."},
		{"empty input", "", 3, "...", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := Truncate(tt.s, tt.n, tt.suffix)
			if got != tt.want {
				t.Errorf("Truncate(%q, %d, %q) = %q, want %q", tt.s, tt.n, tt.suffix, got, tt.want)
			}
			if !utf8.ValidString(got) {
				t.Errorf("Truncate(%q, %d, %q) = %q is not valid UTF-8", tt.s, tt.n, tt.suffix, got)
			}
		})
	}
}
