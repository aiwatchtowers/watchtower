package claude

import (
	"strings"
	"testing"
)

// TestDescribeOutputDisclosesNoContent is the point of the helper: the raw CLI
// output is model text derived from private Slack/mail/calendar content, and
// the description travels into the daemon log, pipeline_runs.error_msg, and
// the Desktop UI. No run of the input may appear in the output.
func TestDescribeOutputDisclosesNoContent(t *testing.T) {
	secret := "Northwind acquisition closes Friday, do not tell the board — legal is reviewing"
	got := DescribeOutput([]byte(secret))

	// Short stopwords are skipped: a 4-char run is already well past anything
	// the fixed labels or the hex hash could collide with by chance.
	for _, word := range strings.Fields(secret) {
		if len(word) < 4 {
			continue
		}
		if strings.Contains(got, word) {
			t.Errorf("DescribeOutput leaked %q from the input: %s", word, got)
		}
	}
}

// TestDescribeOutputStaysDiagnostic guards the other half of the trade: the
// description must still tell a reader what they are looking at.
func TestDescribeOutputStaysDiagnostic(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{"html error page", "<html><body>502 Bad Gateway</body></html>", "looks like HTML or XML"},
		{"malformed json", `{"result": unterminated`, "looks like malformed JSON"},
		{"bare json string", `"just a string"`, "looks like a bare JSON string"},
		{"plain text", "Not logged in", "looks like plain text"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := DescribeOutput([]byte(tt.input))
			if !strings.Contains(got, tt.want) {
				t.Errorf("DescribeOutput(%s) = %q; want it to classify as %q", tt.name, got, tt.want)
			}
			if !strings.Contains(got, "sha256:") {
				t.Errorf("DescribeOutput = %q; want a hash so identical failures correlate", got)
			}
		})
	}
}

// TestDescribeOutputEmpty covers the degenerate input: no length, no hash of
// nothing, just the fact that the CLI returned nothing at all.
func TestDescribeOutputEmpty(t *testing.T) {
	for _, in := range []string{"", "   \n\t "} {
		if got := DescribeOutput([]byte(in)); got != "empty output" {
			t.Errorf("DescribeOutput(%q) = %q; want %q", in, got, "empty output")
		}
	}
}

// TestDescribeOutputHashIsStableAndDistinguishing keeps the hash useful: the
// same failing output must fingerprint the same across runs, and a different
// one must look different.
func TestDescribeOutputHashIsStableAndDistinguishing(t *testing.T) {
	a := DescribeOutput([]byte("some failure"))
	if b := DescribeOutput([]byte("some failure")); a != b {
		t.Errorf("same input described differently: %q vs %q", a, b)
	}
	if c := DescribeOutput([]byte("another failure")); a == c {
		t.Errorf("different inputs described identically: %q", a)
	}
}
