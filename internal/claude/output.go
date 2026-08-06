package claude

import (
	"bytes"
	"crypto/sha256"
	"fmt"
)

// DescribeOutput renders CLI output the parser could not understand as a
// diagnostic fingerprint that carries none of the output itself.
//
// The raw output is model text derived from private Slack/mail/calendar
// content, and a parse error travels a long way: wrapped with %w into the
// daemon log, persisted in pipeline_runs.error_msg, and rendered in the
// Desktop UI. Echoing a prefix of it leaks that content into all three.
//
// What survives is what a reader actually debugs with: the byte length
// (empty vs truncated vs a full response), a shape guess from the leading
// byte (an HTML error page and a malformed JSON object are different bugs),
// and a short content hash so the same failure can be correlated across runs
// and matched against an output reproduced locally.
func DescribeOutput(output []byte) string {
	trimmed := bytes.TrimSpace(output)
	if len(trimmed) == 0 {
		return "empty output"
	}
	sum := sha256.Sum256(trimmed)
	return fmt.Sprintf("%d bytes, %s, sha256:%x", len(trimmed), classifyOutput(trimmed), sum[:4])
}

// classifyOutput guesses the shape of output from its first byte, returning
// one of a fixed set of labels. It never echoes a byte of the input.
func classifyOutput(trimmed []byte) string {
	switch trimmed[0] {
	case '{', '[':
		return "looks like malformed JSON"
	case '<':
		return "looks like HTML or XML"
	case '"':
		return "looks like a bare JSON string"
	default:
		return "looks like plain text"
	}
}
