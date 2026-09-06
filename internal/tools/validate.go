package tools

import (
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"
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

// dateBound validates a YYYY-MM-DD filter date and widens it to an ISO8601
// bound for created_at comparison. "" passes through as "no filter"; a
// malformed date is a model-facing *ValidationError.
func dateBound(date, field, timeSuffix string) (string, error) {
	if date == "" {
		return "", nil
	}
	if _, err := time.Parse("2006-01-02", date); err != nil {
		return "", &ValidationError{Msg: "invalid " + field + " date " + strconv.Quote(date) + ": must be YYYY-MM-DD"}
	}
	return date + timeSuffix, nil
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
