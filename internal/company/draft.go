package company

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"watchtower/internal/companybundle"
	"watchtower/internal/fsutil"
)

// The wizard draft (<workspace>/company/draft.json, 0600): every field the
// person setting up typed so far, secrets included, except the Slack
// configuration token, which is never written. Only `company draft
// save|discard`, `company check` (MarkDraftChecked) and `company publish`
// (DiscardDraft) write it, under draft.json.lock.

const (
	draftFile      = draftSlug + ".json"
	badDraftPrefix = draftFile + ".bad-"
	// badDraftStamp is the UTC time an unreadable draft was set aside.
	badDraftStamp = "20060102T150405Z"
	// BadDraftMaxAge is how long a set-aside draft (and the secrets in it)
	// stays before the daemon deletes it.
	BadDraftMaxAge = 30 * 24 * time.Hour
)

// draftVendors are the services a draft may name, in the wizard's order.
var draftVendors = []string{"slack", "google", "atlassian", "linear", "microsoft"}

// DraftSlack is the draft's only Slack value: a reference to the app whose
// setup record (plan B) owns its ids and stage.
type DraftSlack struct {
	AppID string `json:"app_id,omitempty"`
}

// Draft is the wizard's progress.
type Draft struct {
	Company   string                   `json:"company"`
	Slug      string                   `json:"slug,omitempty"`
	Services  []string                 `json:"services"`
	Step      string                   `json:"step"`
	StartedAt time.Time                `json:"started_at"`
	Slack     DraftSlack               `json:"slack"`
	Google    *companybundle.Google    `json:"google,omitempty"`
	Atlassian *companybundle.Atlassian `json:"atlassian,omitempty"`
	Linear    *companybundle.Linear    `json:"linear,omitempty"`
	Microsoft *companybundle.Microsoft `json:"microsoft,omitempty"`
	DenyHosts []string                 `json:"deny_hosts,omitempty"`
	Skipped   []string                 `json:"skipped,omitempty"`
	// Checked maps a vendor to CheckHash of the values its check passed
	// with; a step whose values differ now is unchecked (A28).
	Checked          map[string]string `json:"checked,omitempty"`
	MicrosoftWaiting bool              `json:"microsoft_waiting,omitempty"`
}

// DraftState is what LoadDraft found.
type DraftState string

const (
	DraftNone       DraftState = "none"
	DraftOK         DraftState = "ok"
	DraftUnreadable DraftState = "unreadable"
)

// ErrSlackTokenInDraft refuses a draft that carries a Slack configuration
// token: it is used once and never stored.
var ErrSlackTokenInDraft = errors.New("the Slack configuration token is never stored in the draft")

// errDraftDamaged marks a draft.json that is there but does not decode or
// validate: it is set aside, unlike an I/O error, which is returned.
var errDraftDamaged = errors.New("damaged draft")

func (s Store) draftPath() string { return filepath.Join(s.Dir, draftFile) }

// isSlackToken reports a Slack token (configuration xoxe.…/xoxe-…, or any
// other xox?- token) pasted into a field, surrounding spaces ignored.
func isSlackToken(v string) bool {
	v = strings.TrimSpace(v)
	if strings.HasPrefix(v, "xoxe.") {
		return true
	}
	return len(v) > 5 && strings.HasPrefix(v, "xox") && v[4] == '-' && v[3] >= 'a' && v[3] <= 'z'
}

// hasSlackToken walks every string of a decoded JSON value.
func hasSlackToken(v any) bool {
	switch v := v.(type) {
	case string:
		return isSlackToken(v)
	case []any:
		return slices.ContainsFunc(v, hasSlackToken)
	case map[string]any:
		for _, x := range v {
			if hasSlackToken(x) {
				return true
			}
		}
	}
	return false
}

// ParseDraftJSON decodes a draft from the wizard: one JSON object, unknown
// fields refused (a token field with ErrSlackTokenInDraft), and so is any
// value that is a Slack token.
func ParseDraftJSON(raw []byte) (Draft, error) {
	if len(raw) > maxFileBytes {
		return Draft{}, errors.New("draft too large")
	}
	var generic any
	if err := json.Unmarshal(raw, &generic); err != nil {
		return Draft{}, fmt.Errorf("decoding draft: %w", err)
	}
	if _, ok := generic.(map[string]any); !ok {
		return Draft{}, errors.New("decoding draft: not a JSON object")
	}
	if hasSlackToken(generic) {
		return Draft{}, ErrSlackTokenInDraft
	}
	var d Draft
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&d); err != nil {
		if field, ok := strings.CutPrefix(err.Error(), `json: unknown field "`); ok && strings.Contains(strings.ToLower(field), "token") {
			return Draft{}, ErrSlackTokenInDraft
		}
		return Draft{}, fmt.Errorf("decoding draft: %w", err)
	}
	return d, nil
}

// validate checks the draft's names (not its values: a draft holds what was
// typed so far).
func (d Draft) validate() error {
	for _, list := range [][]string{d.Services, d.Skipped} {
		for _, v := range list {
			if !slices.Contains(draftVendors, v) {
				return fmt.Errorf("unknown service %q", v)
			}
		}
	}
	for v := range d.Checked {
		if !slices.Contains(draftVendors, v) {
			return fmt.Errorf("unknown checked service %q", v)
		}
	}
	if d.Slug != "" && (!slugRE.MatchString(d.Slug) || d.Slug == draftSlug) {
		return fmt.Errorf("invalid company slug %q", d.Slug)
	}
	return nil
}

// readDraft reads draft.json: a missing file is fs.ErrNotExist, one that does
// not decode or validate (or is not a regular file) wraps errDraftDamaged,
// anything else is an I/O error.
func readDraft(path string) (Draft, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		return Draft{}, err
	}
	if !fi.Mode().IsRegular() {
		return Draft{}, fmt.Errorf("%w: not a regular file", errDraftDamaged)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return Draft{}, err
	}
	d, err := ParseDraftJSON(raw)
	if err == nil {
		err = d.validate()
	}
	if err != nil {
		return Draft{}, fmt.Errorf("%w: %w", errDraftDamaged, err)
	}
	return d, nil
}

// badDrafts lists the set-aside drafts, oldest name first (the stamp sorts).
func (s Store) badDrafts() ([]string, error) {
	des, err := os.ReadDir(s.Dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading company directory: %w", err)
	}
	var out []string
	for _, de := range des {
		if strings.HasPrefix(de.Name(), badDraftPrefix) {
			out = append(out, de.Name())
		}
	}
	slices.Sort(out)
	return out, nil
}

// lockDraft takes draft.json.lock (creating the directory, 0700).
func (s Store) lockDraft() (func(), error) {
	if err := fsutil.MakePrivateDir(s.Dir); err != nil {
		return nil, fmt.Errorf("creating company directory: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), saveLockWait)
	defer cancel()
	unlock, err := fsutil.LockFile(ctx, s.draftPath()+".lock")
	if err != nil {
		return nil, fmt.Errorf("locking the company draft: %w", err)
	}
	return unlock, nil
}

// LoadDraft returns the wizard draft. A draft.json that cannot be read is
// renamed draft.json.bad-<now, UTC> (0600, never deleted here) and older
// set-aside drafts are deleted; the state is then unreadable, and stays so
// (with the newest set-aside name) until a draft is saved or discarded.
func (s Store) LoadDraft(now time.Time) (Draft, DraftState, string, error) {
	if _, err := os.Stat(s.Dir); errors.Is(err, fs.ErrNotExist) {
		return Draft{}, DraftNone, "", nil
	}
	unlock, err := s.lockDraft()
	if err != nil {
		return Draft{}, DraftNone, "", err
	}
	defer unlock()
	d, err := readDraft(s.draftPath())
	switch {
	case err == nil:
		return d, DraftOK, "", nil
	case errors.Is(err, fs.ErrNotExist):
		bad, err := s.badDrafts()
		if err != nil {
			return Draft{}, DraftNone, "", err
		}
		if len(bad) == 0 {
			return Draft{}, DraftNone, "", nil
		}
		return Draft{}, DraftUnreadable, bad[len(bad)-1], nil
	case !errors.Is(err, errDraftDamaged):
		return Draft{}, DraftNone, "", fmt.Errorf("reading the company draft: %w", err)
	}
	name, err := s.setDraftAside(now)
	if err != nil {
		return Draft{}, DraftNone, "", err
	}
	if name == "" {
		return Draft{}, DraftNone, "", nil
	}
	return Draft{}, DraftUnreadable, name, nil
}

// setDraftAside renames a damaged draft.json to draft.json.bad-<now, UTC>
// (0600) and deletes older set-aside drafts; held under the draft lock. A
// draft.json that is not a regular file (a link, a directory) holds nothing
// typed: it is removed, never followed, and the newest older set-aside
// draft (if any) is named.
func (s Store) setDraftAside(now time.Time) (string, error) {
	fi, err := os.Lstat(s.draftPath())
	if err != nil {
		return "", fmt.Errorf("setting the unreadable draft aside: %w", err)
	}
	if !fi.Mode().IsRegular() {
		if err := os.Remove(s.draftPath()); err != nil {
			return "", fmt.Errorf("removing draft.json, not a regular file: %w", err)
		}
		bad, err := s.badDrafts()
		if err != nil || len(bad) == 0 {
			return "", err
		}
		return bad[len(bad)-1], nil
	}
	name := badDraftPrefix + now.UTC().Format(badDraftStamp)
	path := filepath.Join(s.Dir, name)
	if err := os.Rename(s.draftPath(), path); err != nil {
		return "", fmt.Errorf("setting the unreadable draft aside: %w", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		return "", fmt.Errorf("setting the unreadable draft aside: %w", err)
	}
	bad, err := s.badDrafts()
	if err != nil {
		return "", err
	}
	for _, b := range bad {
		if b != name {
			if err := os.Remove(filepath.Join(s.Dir, b)); err != nil && !errors.Is(err, fs.ErrNotExist) {
				return "", fmt.Errorf("deleting an older unreadable draft: %w", err)
			}
		}
	}
	return name, nil
}

// SaveDraft writes d as draft.json (0600) through a temp file and a rename.
// It keeps the stored draft's start time and its checked marks: those are
// written only by MarkDraftChecked, so a save racing a check never drops
// the check's result, and an edited value un-checks by its hash.
func (s Store) SaveDraft(d Draft) error {
	if err := d.validate(); err != nil {
		return err
	}
	unlock, err := s.lockDraft()
	if err != nil {
		return err
	}
	defer unlock()
	d.Checked = nil
	cur, err := readDraft(s.draftPath())
	switch {
	case err == nil:
		d.Checked = cur.Checked
		if !cur.StartedAt.IsZero() {
			d.StartedAt = cur.StartedAt
		}
	case !errors.Is(err, fs.ErrNotExist):
		// A damaged draft is set aside by LoadDraft (which the wizard
		// runs first), never overwritten with its typed secrets.
		return fmt.Errorf("the stored company draft cannot be read; load it first: %w", err)
	}
	if d.Services == nil {
		d.Services = []string{}
	}
	return s.writeDraft(d)
}

// MarkDraftChecked records that vendor's check passed with the values whose
// CheckHash is hash (taken when the check started: a value edited since
// leaves the step unchecked). No draft is an error.
func (s Store) MarkDraftChecked(vendor, hash string) error {
	if !slices.Contains(draftVendors, vendor) {
		return fmt.Errorf("unknown service %q", vendor)
	}
	unlock, err := s.lockDraft()
	if err != nil {
		return err
	}
	defer unlock()
	d, err := readDraft(s.draftPath())
	if err != nil {
		return fmt.Errorf("reading the company draft: %w", err)
	}
	if d.Checked == nil {
		d.Checked = map[string]string{}
	}
	d.Checked[vendor] = hash
	return s.writeDraft(d)
}

// writeDraft encodes d under the held lock; a Slack token never lands.
func (s Store) writeDraft(d Draft) error {
	data, err := json.MarshalIndent(d, "", "  ")
	if err != nil {
		return fmt.Errorf("encoding draft: %w", err)
	}
	if _, err := ParseDraftJSON(data); err != nil {
		return err
	}
	return fsutil.WriteFileAtomic(s.draftPath(), append(data, '\n'), 0o600)
}

// DiscardDraft deletes the draft and every set-aside draft. Nothing to
// delete is not an error.
func (s Store) DiscardDraft() error {
	if _, err := os.Stat(s.Dir); errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	unlock, err := s.lockDraft()
	if err != nil {
		return err
	}
	defer unlock()
	bad, err := s.badDrafts()
	if err != nil {
		return err
	}
	for _, name := range append(bad, draftFile) {
		if err := os.Remove(filepath.Join(s.Dir, name)); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("deleting %s: %w", name, err)
		}
	}
	return nil
}

// CleanStaleBadDrafts deletes set-aside drafts older than BadDraftMaxAge (by
// the stamp in the name, else the file's time). A wizard holding the draft
// lock defers it to the next call.
func (s Store) CleanStaleBadDrafts(now time.Time) error {
	bad, err := s.badDrafts()
	if err != nil || len(bad) == 0 {
		return err
	}
	unlock, ok, err := fsutil.TryLockFile(s.draftPath() + ".lock")
	if err != nil || !ok {
		return err
	}
	defer unlock()
	for _, name := range bad {
		path := filepath.Join(s.Dir, name)
		at, err := time.Parse(badDraftStamp, strings.TrimPrefix(name, badDraftPrefix))
		if err != nil {
			fi, statErr := os.Lstat(path)
			if statErr != nil {
				continue
			}
			at = fi.ModTime()
		}
		if now.Sub(at) <= BadDraftMaxAge {
			continue
		}
		if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("deleting %s: %w", name, err)
		}
	}
	return nil
}

// checkValues are the values a vendor's check uses (nil: nothing to check).
func checkValues(vendor string, d Draft) []string {
	switch vendor {
	case "slack":
		if d.Slack.AppID != "" {
			return []string{d.Slack.AppID}
		}
	case "google":
		if d.Google != nil {
			return []string{d.Google.ClientID, d.Google.ClientSecret}
		}
	case "atlassian":
		if d.Atlassian != nil {
			return []string{d.Atlassian.ClientID, d.Atlassian.ClientSecret, d.Atlassian.Site}
		}
	case "linear":
		if d.Linear != nil {
			return []string{d.Linear.ClientID}
		}
	case "microsoft":
		if d.Microsoft != nil {
			return []string{d.Microsoft.ClientID, d.Microsoft.TenantID}
		}
	}
	return nil
}

// CheckHash is the sha256 (hex) of the values vendor's check uses in d, ""
// when the step holds none.
func CheckHash(vendor string, d Draft) string {
	vals := checkValues(vendor, d)
	if vals == nil {
		return ""
	}
	sum := sha256.Sum256([]byte(strings.Join(append([]string{vendor}, vals...), "\x00")))
	return hex.EncodeToString(sum[:])
}

// IsChecked reports whether vendor's step passed its check with the values
// it holds now.
func (d Draft) IsChecked(vendor string) bool {
	h := CheckHash(vendor, d)
	return h != "" && d.Checked[vendor] == h
}

// CheckedVendors are the vendors IsChecked reports, in the wizard's order.
func (d Draft) CheckedVendors() []string {
	out := []string{}
	for _, v := range draftVendors {
		if d.IsChecked(v) {
			out = append(out, v)
		}
	}
	return out
}
