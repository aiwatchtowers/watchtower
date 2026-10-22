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

// defaultPromptCall is the SDK call RenderOwnerCopy redirects.
const defaultPromptCall = "builtin.defaultPrompt("

// The names RenderOwnerCopy declares in the script; the double underscore
// keeps them clear of a recipe's own names (the render refuses a script that
// already uses them).
const (
	promptsConst  = "__builtinPrompts"
	promptsHelper = "__builtinPrompt"
)

// RenderOwnerCopy is e's shipped recipe with the given prompts written into
// it as literal text — the owner's copy a customised prompt becomes. Only the
// script block changes: it starts with
//
//	const __builtinPrompts = {
//	  "brief": "<the prompt as a JSON string literal>",
//	};
//	const __builtinPrompt = (name) => typeof __builtinPrompts[name] === "string"
//	  ? __builtinPrompts[name] : builtin.defaultPrompt(name);
//
// and every builtin.defaultPrompt( call in it becomes __builtinPrompt(, so a
// call whose name is a variable (the shipped loop) reads the same text, and a
// prompt name not given keeps the shipped default at run time. A JSON string
// literal is a valid JavaScript string whatever the text holds (backticks,
// %s, U+2028/U+2029 are escaped or plain), and it is one line, so it can
// never close the script's fence. prompts must name at least one of e's
// prompts, none other, each with non-blank text; the result must parse in
// e's scope.
func RenderOwnerCopy(e Entry, prompts map[string]string) ([]byte, error) {
	if len(prompts) == 0 {
		return nil, fmt.Errorf("built-in %s: rendering the copy needs at least one prompt", e.ID)
	}
	var names []string
	for _, p := range e.Prompts {
		if _, ok := prompts[p.Name]; ok {
			names = append(names, p.Name)
		}
	}
	if len(names) != len(prompts) {
		return nil, fmt.Errorf("built-in %s: prompts %v are not all among its prompts", e.ID, slices.Sorted(maps.Keys(prompts)))
	}
	shipped, err := ParseShipped(e)
	if err != nil {
		return nil, fmt.Errorf("built-in %s: the shipped recipe does not parse: %w", e.ID, err)
	}
	if strings.Contains(shipped.Script, promptsHelper) {
		return nil, fmt.Errorf("built-in %s: the shipped script already uses %q", e.ID, promptsHelper)
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
	decl.WriteString("const " + promptsHelper + " = (name) => typeof " + promptsConst + "[name] === \"string\"\n")
	decl.WriteString("  ? " + promptsConst + "[name] : " + defaultPromptCall + "name);\n")

	lines := strings.SplitAfter(string(e.Recipe), "\n")
	at := shipped.ScriptLine - 1                    // the script's first line, 0-based
	end := at + strings.Count(shipped.Script, "\n") // the closing fence
	if at < 1 || end > len(lines) {
		return nil, fmt.Errorf("built-in %s: script lines %d..%d are outside the recipe", e.ID, at+1, end)
	}
	var out bytes.Buffer
	out.WriteString(strings.Join(lines[:at], ""))
	out.WriteString(decl.String())
	out.WriteString(strings.ReplaceAll(strings.Join(lines[at:end], ""), defaultPromptCall, promptsHelper+"("))
	out.WriteString(strings.Join(lines[end:], ""))
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
