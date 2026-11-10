package automations

import "testing"

func TestLLMCallSites(t *testing.T) {
	for _, tc := range []struct {
		name, script string
		want         int
	}{
		{"none", "return 1\n", 0},
		{"one call", "const a = llm('light', 'hi')\n", 1},
		{"two calls", "llm('light', 'a')\nllm('strong', 'b')\n", 2},
		{"space before paren", "const a = llm ('light', 'x')\n", 1},
		{"newline before paren", "const a = llm\n('light', 'x')\n", 1},
		{"line comment", "// llm('light', 'x')\nreturn 1\n", 0},
		{"block comment", "/* llm('light', 'x') */ return 1\n", 0},
		{"single-quoted string", "const s = 'llm(x)'\n", 0},
		{"double-quoted string", "const s = \"llm(x)\"\n", 0},
		{"template text", "const s = `call llm(x) later`\n", 0},
		{"template expression", "const s = `a ${llm('light', 'x')} b`\n", 1},
		{"property access", "x.llm('light', 'y')\n", 0},
		{"property access after space", "x. llm('light', 'y')\n", 0},
		{"spread is not a dot", "f(...llm('light', 'y'))\n", 1},
		{"object key", "const o = {llm: 1}\n", 0},
		{"bare reference", "const f = llm\n", 0},
		{"longer identifier", "myllm('a')\nllmish('b')\n", 0},
		{"inside a block", "if (x) { llm('light', 'y') }\n", 1},
		{"after a string with an escaped quote", "const s = 'it\\'s'; llm('light', 'y')\n", 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := LLMCallSites(tc.script); got != tc.want {
				t.Errorf("LLMCallSites(%q) = %d, want %d", tc.script, got, tc.want)
			}
		})
	}
}

// Moving a call keeps the count: only an added call site changes it.
func TestLLMCallSites_MovedCallKeepsTheCount(t *testing.T) {
	before := "const a = llm('light', 'x')\nconst b = 2\nreturn a\n"
	moved := "const b = 2\nconst a = llm('light', 'x')\nreturn a\n"
	added := moved + "llm('light', 'again')\n"
	if LLMCallSites(before) != LLMCallSites(moved) {
		t.Fatalf("a moved call changed the count: %d vs %d", LLMCallSites(before), LLMCallSites(moved))
	}
	if LLMCallSites(added) <= LLMCallSites(moved) {
		t.Fatalf("an added call did not raise the count")
	}
}
