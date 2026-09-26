package prompts

import (
	"strings"
	"testing"
)

func TestExtractJSONObject_FencedInput(t *testing.T) {
	raw := "```json\n{\"name\":\"X\",\"instruction\":\"watch it\"}\n```"
	got, err := ExtractJSONObject(raw)
	if err != nil {
		t.Fatalf("ExtractJSONObject: %v", err)
	}
	if got != `{"name":"X","instruction":"watch it"}` {
		t.Fatalf("unexpected extraction: %q", got)
	}
}

func TestExtractJSONObject_ProseWrappedInput(t *testing.T) {
	raw := "Sure, here is the result you asked for:\n{\"events\":[{\"summary\":\"a {nested} brace\"}]}\nLet me know if you need anything else."
	got, err := ExtractJSONObject(raw)
	if err != nil {
		t.Fatalf("ExtractJSONObject: %v", err)
	}
	if !strings.HasPrefix(got, "{") || !strings.HasSuffix(got, "}") {
		t.Fatalf("extraction not sliced to the object: %q", got)
	}
	if !strings.Contains(got, `"summary"`) {
		t.Fatalf("object content lost: %q", got)
	}
}

func TestExtractJSONObject_NoJSONErrors(t *testing.T) {
	if _, err := ExtractJSONObject("no object here, sorry"); err == nil {
		t.Fatal("expected error for input without a JSON object")
	}
	if _, err := ExtractJSONObject(""); err == nil {
		t.Fatal("expected error for empty input")
	}
}
