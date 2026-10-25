package media

import (
	"context"
	"errors"
	"regexp"

	"watchtower/internal/db"
	"watchtower/internal/media/webfetch"
)

// ErrorClasses are the only values a media_items.error column holds.
var ErrorClasses = db.MediaErrorClasses

var (
	// ErrGone: the item's bytes are no longer there (the file, message or
	// attachment is gone, or the locator points outside what may be read).
	ErrGone = errors.New("media: the item is gone")
	// ErrTooLarge: the item is over the download cap.
	ErrTooLarge = errors.New("media: the item is too large")
)

// modelError marks a failed model call; convertError a failed sips run;
// openError a local temp-file failure.
type (
	modelError   struct{ err error }
	convertError struct{ err error }
	openError    struct{ err error }
)

func (e modelError) Error() string   { return "model call: " + e.err.Error() }
func (e modelError) Unwrap() error   { return e.err }
func (e convertError) Error() string { return "sips: " + e.err.Error() }
func (e convertError) Unwrap() error { return e.err }
func (e openError) Error() string    { return "temp file: " + e.err.Error() }
func (e openError) Unwrap() error    { return e.err }

// ClassifyError maps err to one of ErrorClasses. A sips failure is
// convert_failed even when it timed out; an unknown error is other.
func ClassifyError(err error) string {
	var conv convertError
	var model modelError
	var open openError
	switch {
	case err == nil:
		return ""
	case errors.As(err, &conv):
		return "convert_failed"
	case errors.Is(err, context.Canceled):
		return "canceled"
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.Is(err, webfetch.ErrRefused):
		return "refused"
	case errors.Is(err, webfetch.ErrNotFound), errors.Is(err, ErrGone):
		return "not_found"
	case errors.Is(err, webfetch.ErrTooLarge), errors.Is(err, ErrTooLarge):
		return "too_large"
	case errors.Is(err, webfetch.ErrUnsupported):
		return "unsupported"
	case errors.Is(err, ErrBadOutput):
		return "bad_output"
	case errors.As(err, &model):
		return "model_error"
	case errors.As(err, &open):
		return "open_failed"
	}
	return "other"
}

// urlQueryRe matches the query and fragment of a URL inside a text.
var urlQueryRe = regexp.MustCompile(`(?i)(\b[a-z][a-z0-9+.-]*://[^\s?#"'<>]*)[?#][^\s"'<>]*`)

// redactURLs cuts the query and fragment off every URL in s, for the log.
func redactURLs(s string) string {
	return urlQueryRe.ReplaceAllString(s, "$1?…")
}
