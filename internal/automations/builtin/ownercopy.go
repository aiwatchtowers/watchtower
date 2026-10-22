package builtin

import (
	"bytes"
	"encoding/json"
	"fmt"
	"maps"
	"slices"
	"strings"

	"watchtower/internal/automations"
)

// defaultPromptCall is the SDK call RenderOwnerCopy replaces.
const defaultPromptCall = "builtin.defaultPrompt("

// promptsConst is the script constant RenderOwnerCopy declares.
const promptsConst = "prompts"

// RenderOwnerCopy is e's shipped recipe with its prompts written into it as
// literal text, the owner's copy a customised prompt becomes: the script
// starts with
//
//	const prompts = {
//	  "brief": "<the prompt as a JSON string literal>",
//	  ...
//	};
//
// and every builtin.defaultPrompt(<arg>) call becomes prompts[<arg>], so a
// call whose name is a variable (the shipped loop) reads the same text. A JSON
// string literal is a valid JavaScript string whatever the text holds
// (backticks, %s, U+2028/U+2029 are escaped or plain), and it is one line, so
// it can never close the script's fence. prompts must hold exactly e's prompt
// names, each with non-blank text; the result must parse in e's scope.
func RenderOwnerCopy(e Entry, prompts map[string]string) ([]byte, error) {
	names := make([]string, 0, len(e.Prompts))
	for _, p := range e.Prompts {
		names = append(names, p.Name)
	}
	if got := slices.Sorted(maps.Keys(prompts)); !slices.Equal(got, slices.Sorted(slices.Values(names))) {
		return nil, fmt.Errorf("built-in %s: rendering the copy needs prompts %v, got %v", e.ID, names, got)
	}
	shipped, err := ParseShipped(e)
	if err != nil {
		return nil, fmt.Errorf("built-in %s: the shipped recipe does not parse: %w", e.ID, err)
	}
	if strings.Contains(shipped.Script, "const "+promptsConst) || strings.Contains(shipped.Script, "let "+promptsConst) {
		return nil, fmt.Errorf("built-in %s: the shipped script already declares %q", e.ID, promptsConst)
	}
	var decl strings.Builder
	decl.WriteString("const " + promptsConst + " = {\n")
	for _, name := range names {
		text := prompts[name]
		if strings.TrimSpace(text) == "" {
			return nil, fmt.Errorf("built-in %s: prompt %q is empty", e.ID, name)
		}
		fmt.Fprintf(&decl, "  %s: %s,\n", jsString(name), jsString(text))
	}
	decl.WriteString("};\n")

	lines := strings.SplitAfter(string(e.Recipe), "\n")
	at := shipped.ScriptLine - 1 // the script's first line, 0-based
	if at < 1 || at > len(lines) {
		return nil, fmt.Errorf("built-in %s: script line %d is outside the recipe", e.ID, shipped.ScriptLine)
	}
	var out bytes.Buffer
	for _, l := range lines[:at] {
		out.WriteString(l)
	}
	out.WriteString(decl.String())
	script, err := replaceDefaultPromptCalls(strings.Join(lines[at:], ""))
	if err != nil {
		return nil, fmt.Errorf("built-in %s: %w", e.ID, err)
	}
	out.WriteString(script)
	if _, err := automations.ParseRecipe(e.ID, out.Bytes(), scopeOf(e)); err != nil {
		return nil, fmt.Errorf("built-in %s: the rendered copy does not parse: %w", e.ID, err)
	}
	return out.Bytes(), nil
}

// jsString is s as a JSON string literal (a valid JavaScript string literal:
// encoding/json escapes U+2028 and U+2029 too).
func jsString(s string) string {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(s) // a string always encodes
	return strings.TrimSuffix(b.String(), "\n")
}

// replaceDefaultPromptCalls turns every builtin.defaultPrompt(<arg>) in src
// into prompts[<arg>]; <arg> ends at the parenthesis that closes the call
// (nested parentheses and quoted strings skipped).
func replaceDefaultPromptCalls(src string) (string, error) {
	var out strings.Builder
	for {
		i := strings.Index(src, defaultPromptCall)
		if i < 0 {
			out.WriteString(src)
			return out.String(), nil
		}
		out.WriteString(src[:i])
		rest := src[i+len(defaultPromptCall):]
		end, err := closingParen(rest)
		if err != nil {
			return "", err
		}
		out.WriteString(promptsConst + "[" + rest[:end] + "]")
		src = rest[end+1:]
	}
}

// closingParen is the index in s of the ")" that closes a call whose "(" was
// just before s.
func closingParen(s string) (int, error) {
	depth := 0
	var quote byte
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case quote != 0:
			if c == '\\' {
				i++
			} else if c == quote {
				quote = 0
			}
		case c == '"' || c == '\'' || c == '`':
			quote = c
		case c == '(':
			depth++
		case c == ')':
			if depth == 0 {
				return i, nil
			}
			depth--
		}
	}
	return 0, fmt.Errorf("an unclosed %s call", defaultPromptCall)
}
