package caldav

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"

	"github.com/emersion/go-ical"
)

// FetchICS downloads and parses a secret ICS feed (Google Calendar's
// "Secret address in iCal format", Outlook published calendars). The feed
// URL is a credential — callers must never log or persist it outside the
// account's CredentialStore.
func FetchICS(ctx context.Context, feedURL string) (*ical.Calendar, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, feedURL, nil)
	if err != nil {
		return nil, fmt.Errorf("building ics request: %w", err)
	}
	client := &http.Client{Timeout: httpTimeout}
	// #nosec G704 -- fetching a user-supplied feed URL is this integration's
	// entire purpose: the owner connects their own secret ICS address (Google
	// secret iCal URL, Outlook published calendar) from their own machine.
	// There is no multi-tenant server here to SSRF into.
	resp, err := client.Do(req)
	if err != nil {
		// *url.Error embeds the full request URL — which for a secret feed IS
		// the credential. Unwrap so the URL never lands in logs or the
		// calendar_accounts.error column.
		var uerr *url.Error
		if errors.As(err, &uerr) {
			return nil, fmt.Errorf("fetching ics feed: %w", uerr.Err)
		}
		return nil, fmt.Errorf("fetching ics feed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("fetching ics feed: unexpected status %s", resp.Status)
	}
	cal, err := ical.NewDecoder(resp.Body).Decode()
	if err != nil {
		return nil, fmt.Errorf("parsing ics feed: %w", err)
	}
	return cal, nil
}
