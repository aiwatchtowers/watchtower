package prompts

import (
	"fmt"
	"strings"
)

// ExtractJSONObject tolerantly extracts a JSON object from an AI reply: it
// strips markdown code fences and slices from the first '{' to the last '}'.
// It does not validate the result — the caller unmarshals and reports parse
// errors with its own context.
func ExtractJSONObject(raw string) (string, error) {
	s := strings.TrimSpace(raw)
	s = strings.TrimPrefix(s, "```json")
	s = strings.TrimPrefix(s, "```")
	s = strings.TrimSuffix(s, "```")
	start := strings.Index(s, "{")
	end := strings.LastIndex(s, "}")
	if start < 0 || end < start {
		return "", fmt.Errorf("no JSON object found")
	}
	return s[start : end+1], nil
}
