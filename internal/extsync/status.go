package extsync

import (
	"errors"
	"fmt"
)

// Engine sentinels. A Fetcher maps its provider's auth failures onto these
// (the Confluence fetcher maps jira.ErrAuthRevoked and a 403 naming a
// missing scope), so the engine can record a source status without knowing
// the provider.
var (
	// ErrAuthRevoked: the account's grant is gone; every source of the
	// account stops for the cycle.
	ErrAuthRevoked = errors.New("extsync: authorization revoked")
	// ErrNeedsConsent: the grant lacks the scopes this source needs.
	ErrNeedsConsent = errors.New("extsync: consent required")
	// ErrTooLarge: Fetcher.Download (or a read of the body it returned)
	// hit the size limit; the attachment is stored as too_large.
	ErrTooLarge = errors.New("extsync: download exceeds the size limit")
	// ErrGone: Fetcher.Download found the attachment gone (deleted between
	// Fetch and Download); its row is deleted like a Fetch that returns nil.
	ErrGone = errors.New("extsync: item gone")
)

// Source statuses (the ext_sources.status CHECK).
const (
	statusOK           = "ok"
	statusError        = "error"
	statusNeedsConsent = "needs_consent"
	statusRevoked      = "revoked"
)

// outcome is how one source's run is recorded.
type outcome struct {
	status string
	text   string // the ext_sources.error text
	// accountWide: every source of the same account stops for this run
	// with the same outcome.
	accountWide bool
}

// expected reports whether the outcome is an expected state (the owner must
// re-consent) rather than a failure to surface from Run.
func (o outcome) expected() bool {
	return o.status == statusNeedsConsent || o.status == statusRevoked
}

// err is the error an expected outcome surfaces: its hint, wrapping the
// matching sentinel.
func (o outcome) err() error {
	switch o.status {
	case statusRevoked:
		return fmt.Errorf("%s: %w", o.text, ErrAuthRevoked)
	case statusNeedsConsent:
		return fmt.Errorf("%s: %w", o.text, ErrNeedsConsent)
	}
	return nil
}

func revokedOutcome(jiraAccountID int64) outcome {
	return outcome{status: statusRevoked, accountWide: true, text: fmt.Sprintf(
		"Atlassian sign-in expired — run: watchtower jira login --account %d --with-confluence", jiraAccountID)}
}

func needsConsentOutcome(jiraAccountID int64) outcome {
	return outcome{status: statusNeedsConsent, accountWide: true, text: fmt.Sprintf(
		"Confluence access not granted — run: watchtower jira login --account %d --with-confluence", jiraAccountID)}
}

// classify maps a source run's error to its recorded outcome. The caller
// handles a cancelled ctx before classifying: shutdown is never recorded.
func classify(err error, jiraAccountID int64) outcome {
	switch {
	case err == nil:
		return outcome{status: statusOK}
	case errors.Is(err, ErrAuthRevoked):
		return revokedOutcome(jiraAccountID)
	case errors.Is(err, ErrNeedsConsent):
		return needsConsentOutcome(jiraAccountID)
	default:
		return outcome{status: statusError, text: err.Error()}
	}
}
