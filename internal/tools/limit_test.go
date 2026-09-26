package tools

import "testing"

// listLimit applies the default when a caller leaves limit unset and clamps
// oversized requests, so one read tool call can never dump an entire table into
// the model's context window.
func TestListLimit(t *testing.T) {
	cases := []struct{ in, want int }{
		{0, 50},     // unset → default
		{-5, 50},    // negative → default
		{50, 50},    // in range → unchanged
		{200, 200},  // at the cap → unchanged
		{9999, 200}, // over the cap → clamped
	}
	for _, c := range cases {
		if got := listLimit(c.in); got != c.want {
			t.Errorf("listLimit(%d) = %d, want %d", c.in, got, c.want)
		}
	}
}
