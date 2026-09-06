package tools

import (
	"fmt"
	"slices"
	"strings"
)

// validateEnum returns a model-facing *ValidationError when value is neither
// empty nor one of allowed. Empty means "no filter" and is always valid. The
// message names the bad value and the pipe-joined allowed set, so the model
// learns exactly which argument it got wrong and what it may use instead.
func validateEnum(field, value string, allowed ...string) error {
	if value == "" || slices.Contains(allowed, value) {
		return nil
	}
	return &ValidationError{Msg: fmt.Sprintf("invalid %s %q: must be one of %s", field, value, strings.Join(allowed, "|"))}
}

// firstErr returns the first non-nil error, or nil.
func firstErr(errs ...error) error {
	for _, e := range errs {
		if e != nil {
			return e
		}
	}
	return nil
}
