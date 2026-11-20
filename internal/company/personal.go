package company

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"watchtower/internal/companybundle"
	"watchtower/internal/db"
)

// OwnProjectWeeklyRelogin is spike S2's answer (#1887 Task 1): whether a
// personal Google project published to production unverified loses its
// refresh token after 7 days. false until the day-8 check proves otherwise
// (outcome A); outcome B sets it true, and the personal path then stamps a
// re-login due date 7 days after each sign-in.
const OwnProjectWeeklyRelogin = false

// personalFallbackName is the company name of a personal bundle whose owner
// is unknown (a Calendar-only grant carries no address).
const personalFallbackName = "My Google project"

// maxPersonalNames bounds SavePersonal's walk over "<owner>", "<owner> (2)"…
const maxPersonalNames = 100

// CheckPersonalGoogle validates an own project's client the way a stored
// personal bundle is read, so a malformed client id or secret is refused
// before any browser opens. It returns the normalized client.
func CheckPersonalGoogle(g companybundle.Google) (companybundle.Google, error) {
	b, err := personalBundle(personalFallbackName, g)
	if err != nil {
		return companybundle.Google{}, err
	}
	return *b.Google, nil
}

// personalBundle is the stored form of a person's own Google project:
// only a google block, personal set, read back through ParseJSON.
func personalBundle(name string, g companybundle.Google) (companybundle.Bundle, error) {
	raw, err := json.Marshal(companybundle.Bundle{V: companybundle.Version, Company: name, Personal: true,
		Google: &companybundle.Google{ClientID: g.ClientID, ClientSecret: g.ClientSecret}})
	if err != nil {
		return companybundle.Bundle{}, fmt.Errorf("encoding own Google project: %w", err)
	}
	b, err := companybundle.ParseJSON(raw, companybundle.OriginLocal)
	if err != nil {
		return companybundle.Bundle{}, fmt.Errorf("own Google project: %w", err)
	}
	return b, nil
}

// SavePersonal stores a person's own Google project as a personal bundle
// (#1887 §4) and returns its slug. It is the only writer of personal: true
// (with OriginLocal; a link, MDM or code can never carry it). The company
// name is owner (the signed-in person), else personalFallbackName.
//
// A personal bundle that already holds the same client is reused, nothing
// written. A name taken by a company, the forced bundle, or another of the
// person's projects (a different client) moves on to "<owner> (2)", "(3)"…,
// so a personal file never overwrites a company's or another project's —
// whose accounts would then need a re-login. Two concurrent saves of the
// same client end on one file: the loser's SaveIfUnchanged sees the winner's
// file and the next pass reuses it.
func SavePersonal(s Store, forcedWire, owner string, g companybundle.Google) (string, error) {
	want, err := CheckPersonalGoogle(g)
	if err != nil {
		return "", err
	}
	base := strings.TrimSpace(owner)
	if _, err := personalBundle(base, want); err != nil {
		// No owner, or not a valid company name (a control character).
		base = personalFallbackName
	}
	for n := 1; n <= maxPersonalNames; n++ {
		st, err := s.read()
		if err != nil {
			return "", err
		}
		overlay(&st, forcedWire)
		if slug, ok := samePersonalProject(st.entries, want); ok {
			return slug, nil
		}
		name := personalName(base, n)
		if nameTaken(st.entries, name) || st.pinned(name) {
			continue
		}
		b, err := personalBundle(name, want)
		if err != nil {
			return "", err
		}
		slug, err := s.SlugFor(name, forcedWire)
		if err != nil {
			return "", err
		}
		switch err := s.SaveIfUnchanged(slug, nil, b); {
		case err == nil:
			return slug, nil
		case errors.Is(err, ErrStoredChanged), errors.Is(err, ErrSlugTaken):
			// Written meanwhile, or a damaged file under the slug: read again.
			continue
		default:
			return "", err
		}
	}
	return "", fmt.Errorf("no free name for the own Google project of %q", base)
}

// personalName is base, then "base (2)", "base (3)"…
func personalName(base string, n int) string {
	if n <= 1 {
		return base
	}
	return fmt.Sprintf("%s (%d)", base, n)
}

// samePersonalProject finds a stored personal bundle holding client g.
func samePersonalProject(entries []Entry, g companybundle.Google) (string, bool) {
	for _, e := range entries {
		if e.Bundle.Personal && !e.Forced && e.Bundle.Google != nil &&
			e.Bundle.Google.ClientID == g.ClientID && e.Bundle.Google.ClientSecret == g.ClientSecret {
			return e.Slug, true
		}
	}
	return "", false
}

// pinned reports whether name is a company forced before (its .seen record,
// readable or most likely its damaged one): SlugFor would hand back the
// pinned slug its accounts still carry, turning them into own-project ones.
func (st *diskState) pinned(name string) bool {
	if _, ok := st.seen[name]; ok {
		return true
	}
	_, ok := st.damagedPin(name)
	return ok
}

// nameTaken reports whether any company (personal or not, forced included)
// already goes by name.
func nameTaken(entries []Entry, name string) bool {
	for _, e := range entries {
		if e.Bundle.Company == name {
			return true
		}
	}
	return false
}

// IsOwnProject reports whether the Google account signs in through a
// person's own Google project (#1887 §4): its company is a personal bundle,
// or it has no company and a legacy per-account credentials file
// (google_credentials_<id>.json from `google add --client-id` before
// personal bundles). A company account (a bridged corp account included) and
// a shared-client account are not. entries is Store.LoadAll's answer; a
// company slug not among them is not counted as own.
func IsOwnProject(a db.GoogleAccount, entries []Entry, hasLegacyCredentials bool) bool {
	if a.CompanySlug == "" {
		return hasLegacyCredentials
	}
	for _, e := range entries {
		if e.Slug == a.CompanySlug {
			return e.Bundle.Personal
		}
	}
	return false
}
