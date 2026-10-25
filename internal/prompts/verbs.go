package prompts

import "fmt"

// CountVerbs is the number of %s verbs in fmt template tmpl when every fmt
// directive in it is a plain %s (%% is a literal percent sign), else -1:
// any other directive — %d, a flag or width (% s, as in "100% sure"), a
// trailing % — would take an argument meant for a %s section or print
// %!(...) in Sprintf. The pipelines that fill a template with their
// sections compare it with their default's count and fall back to the
// default when they differ.
func CountVerbs(tmpl string) int {
	n := 0
	for i := 0; i < len(tmpl); i++ {
		if tmpl[i] != '%' {
			continue
		}
		i++
		switch {
		case i < len(tmpl) && tmpl[i] == '%':
		case i < len(tmpl) && tmpl[i] == 's':
			n++
		default:
			return -1
		}
	}
	return n
}

// PlaceholderNote is the run's note when a template's CountVerbs (got)
// differs from its default's (want) and the default was used.
func PlaceholderNote(got, want int) string {
	if got < 0 {
		return fmt.Sprintf("The prompt has a %% directive other than %%s (write %%%% for a percent sign) where %d %%s placeholders are required — the built-in prompt was used.", want)
	}
	return fmt.Sprintf("The prompt has %d placeholders where %d are required — the built-in prompt was used.", got, want)
}
