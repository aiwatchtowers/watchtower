package company

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"

	"watchtower/internal/companybundle"
	"watchtower/internal/db"
	"watchtower/internal/fsutil"
)

// ChangedAppCode is the account error a changed company app leaves on its
// accounts (Re-login needed: "<company> changed its app"): a Replace confirm
// and a changed forced MDM bundle.
const ChangedAppCode = "company_changed_app"

// VendorAccountSource maps a bundle vendor to its account source in
// db.MarkCompanyAccounts / AccountsByCompany.
var VendorAccountSource = map[string]string{
	"slack": "slack", "google": "google", "atlassian": "jira", "microsoft": "outlook", "linear": "linear",
}

// ChangedAccountSources are the account sources of the changed vendors, in
// the changes' order, each once.
func ChangedAccountSources(changes []Change) []string {
	var out []string
	seen := map[string]bool{}
	for _, c := range changes {
		if src := VendorAccountSource[c.Vendor]; !seen[src] {
			seen[src] = true
			out = append(out, src)
		}
	}
	return out
}

// The last forced bundle seen of a company: .forced-<slug>.seen beside the
// company files (0600). Only ApplyForcedChanges writes it; it also pins the
// forced company's slug (LoadAll, SlugFor).
const (
	seenPrefix = ".forced-"
	seenSuffix = ".seen"
)

// seenSlug returns the slug of a .forced-<slug>.seen file name.
func seenSlug(name string) (string, bool) {
	rest, ok := strings.CutPrefix(name, seenPrefix)
	if !ok {
		return "", false
	}
	slug, ok := strings.CutSuffix(rest, seenSuffix)
	if !ok || !slugRE.MatchString(slug) || slug == draftSlug {
		return "", false
	}
	return slug, true
}

func seenPath(dir, slug string) string { return filepath.Join(dir, seenPrefix+slug+seenSuffix) }

// readSeen reads the last forced bundle seen under slug; fs.ErrNotExist when
// there is none.
func readSeen(dir, slug string) (companybundle.Bundle, error) {
	path := seenPath(dir, slug)
	fi, err := os.Lstat(path)
	if err != nil {
		return companybundle.Bundle{}, err
	}
	if !fi.Mode().IsRegular() || fi.Size() > maxFileBytes {
		return companybundle.Bundle{}, errors.New("not a forced-bundle record")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return companybundle.Bundle{}, err
	}
	return companybundle.ParseJSON(raw, companybundle.OriginMDM)
}

func writeSeen(dir, slug string, b companybundle.Bundle) error {
	data, err := json.MarshalIndent(b, "", "  ")
	if err != nil {
		return fmt.Errorf("encoding forced company bundle: %w", err)
	}
	if err := fsutil.MakePrivateDir(dir); err != nil {
		return fmt.Errorf("creating company directory: %w", err)
	}
	return fsutil.WriteFileAtomic(seenPath(dir, slug), append(data, '\n'), 0o600)
}

// ApplyForcedChanges compares the forced MDM bundle (forcedWire, "" = none)
// with the last one seen of that company and marks the accounts of every
// vendor whose client changed Re-login needed (ChangedAppCode), in one write
// transaction; IT owns the bundle, so nothing asks first. The baseline is
// .forced-<slug>.seen, else the stored bundle of the same company, else none:
// a first sight marks nothing. The record is written last, so a crash before
// it repeats the (idempotent) marking at the next start. The daemon calls it
// once per start, before the first cycle; LoadAll stays a pure read.
func ApplyForcedChanges(d *db.DB, s Store, forcedWire string) (marked []Change, err error) {
	if strings.TrimSpace(forcedWire) == "" {
		return nil, nil
	}
	fb, err := companybundle.Parse(forcedWire, companybundle.OriginMDM)
	if err != nil {
		return nil, fmt.Errorf("forced company bundle: %w", err)
	}
	st, err := s.read()
	if err != nil {
		return nil, err
	}
	var baseline *companybundle.Bundle
	for _, e := range st.entries {
		if e.Bundle.Company == fb.Company {
			stored := e.Bundle
			baseline = &stored
		}
	}
	overlay(&st, forcedWire)
	slug := ""
	for _, e := range st.entries {
		if e.Forced {
			slug = e.Slug
		}
	}
	// The slug is this company's pin or one no record holds, so a readable
	// record is this company's; a damaged one is compared as absent (the
	// stored bundle, or none) and rewritten below.
	if seen, err := readSeen(s.Dir, slug); err == nil && seen.Company == fb.Company {
		if reflect.DeepEqual(seen, fb) {
			return nil, nil
		}
		baseline = &seen
	}
	var changes []Change
	if baseline != nil {
		changes = Changes(*baseline, fb)
	}
	if len(changes) > 0 {
		if _, err := d.MarkCompanyAccounts(slug, ChangedAccountSources(changes), ChangedAppCode); err != nil {
			return nil, fmt.Errorf("marking %s accounts for a new login: %w", slug, err)
		}
	}
	if err := writeSeen(s.Dir, slug, fb); err != nil {
		return nil, fmt.Errorf("recording the forced bundle of %s: %w", slug, err)
	}
	return changes, nil
}
