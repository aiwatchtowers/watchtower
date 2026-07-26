package memory

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// focusFileName is the vault-root file the owner edits to steer memory
// importance. Like map.md/index.md it lives outside vaultSubdirs, but unlike
// them it is owner-authored and read-only from the pipeline's side — nothing
// in this package ever writes it.
const focusFileName = "focus.md"

// focusDirectives is the parsed contents of focus.md: the bulleted node
// references under "## Now" and "## Cooled", trimmed, in document order.
type focusDirectives struct {
	Now    []string
	Cooled []string
}

// parseFocus parses focus.md's fixed two-heading grammar. A line that is,
// after TrimSpace, case-insensitively equal to "## Now" or "## Cooled" opens
// that section; any other line starting with "#" (an unrecognized heading)
// closes whatever section is open. Inside an open section, lines starting
// with "- " are bullets (trimmed of the marker and surrounding space);
// anything else (prose) is ignored. parseFocus is pure — no vault/DB access
// — and an empty/missing raw string yields the zero value.
func parseFocus(raw string) focusDirectives {
	var fd focusDirectives
	section := "" // "" | "now" | "cooled"
	for _, line := range strings.Split(raw, "\n") {
		trimmed := strings.TrimSpace(line)
		switch strings.ToLower(trimmed) {
		case "## now":
			section = "now"
			continue
		case "## cooled":
			section = "cooled"
			continue
		}
		if strings.HasPrefix(trimmed, "#") {
			section = ""
			continue
		}
		if !strings.HasPrefix(trimmed, "- ") {
			continue
		}
		bullet := strings.TrimSpace(strings.TrimPrefix(trimmed, "- "))
		if bullet == "" {
			continue
		}
		switch section {
		case "now":
			fd.Now = append(fd.Now, bullet)
		case "cooled":
			fd.Cooled = append(fd.Cooled, bullet)
		}
	}
	return fd
}

// fingerprint hashes the directive set: sha256 hex over the sorted,
// normalized (lowercased, TrimSpace'd) bullets tagged by section
// ("now:"/"cooled:"). Sorting makes bullet reorder within a section a no-op;
// the section tag makes moving a bullet between sections change the hash.
// The empty directive set hashes to whatever sha256("") happens to be —
// stable and unremarkable, no special-cased sentinel.
func (fd focusDirectives) fingerprint() string {
	tagged := make([]string, 0, len(fd.Now)+len(fd.Cooled))
	for _, b := range fd.Now {
		tagged = append(tagged, "now:"+strings.ToLower(strings.TrimSpace(b)))
	}
	for _, b := range fd.Cooled {
		tagged = append(tagged, "cooled:"+strings.ToLower(strings.TrimSpace(b)))
	}
	sort.Strings(tagged)
	sum := sha256.Sum256([]byte(strings.Join(tagged, "\n")))
	return hex.EncodeToString(sum[:])
}

// readFocusFile reads the vault-root focus.md file. It is owner-authored and
// this package never writes it (mirroring how map.md/index.md are vault-root
// files, but reversed direction). A missing file is a clean miss, not an
// error, so callers can treat "no focus.md yet" the same as "no directives".
func (p *Pipeline) readFocusFile() (string, bool, error) {
	raw, err := os.ReadFile(filepath.Join(p.vault.path, focusFileName))
	if err != nil {
		if os.IsNotExist(err) {
			return "", false, nil
		}
		return "", false, fmt.Errorf("memory: read focus.md: %w", err)
	}
	return string(raw), true, nil
}

// matchFocus resolves a parsed focusDirectives' bullets to memory node ids.
// For each bullet it tries, on the whole trimmed bullet AND on each
// comma-separated fragment: (1) LookupMemoryAlias, (2)
// ListMemoryNodeIDsByTitleMatch. Every id found across those probes is
// unioned into the bullet's section set. A bullet that resolves nothing logs
// once and contributes nothing (not an error — an owner typo shouldn't
// freeze the whole focus step). A node id that lands in both sections is
// kept in Now only (logged once) — Now always wins the tie. A DB error from
// either probe propagates immediately so the caller can freeze the step.
func (p *Pipeline) matchFocus(fd focusDirectives) (now, cooled []string, err error) {
	nowIDs := map[string]bool{}
	if err := p.resolveBulletsInto(fd.Now, nowIDs); err != nil {
		return nil, nil, err
	}
	cooledIDs := map[string]bool{}
	if err := p.resolveBulletsInto(fd.Cooled, cooledIDs); err != nil {
		return nil, nil, err
	}

	for id := range cooledIDs {
		if nowIDs[id] {
			p.logf("memory: focus: node %s matched in both Now and Cooled, keeping Now", id)
			delete(cooledIDs, id)
		}
	}

	return sortedSet(nowIDs), sortedSet(cooledIDs), nil
}

// resolveBulletsInto resolves each bullet to node ids (via matchBullet) and
// unions the hits into dst, logging a no-match line per unresolved bullet.
func (p *Pipeline) resolveBulletsInto(bullets []string, dst map[string]bool) error {
	for _, bullet := range bullets {
		ids, err := p.matchBullet(bullet)
		if err != nil {
			return err
		}
		if len(ids) == 0 {
			p.logf("memory: focus: bullet %q matched nothing", bullet)
			continue
		}
		for id := range ids {
			dst[id] = true
		}
	}
	return nil
}

// matchBullet resolves one bullet (the whole trimmed text plus each
// comma-separated fragment) to a set of node ids via alias lookup and title
// match.
func (p *Pipeline) matchBullet(bullet string) (map[string]bool, error) {
	candidates := []string{bullet}
	for _, frag := range strings.Split(bullet, ",") {
		frag = strings.TrimSpace(frag)
		if frag != "" && frag != bullet {
			candidates = append(candidates, frag)
		}
	}

	ids := map[string]bool{}
	for _, c := range candidates {
		if id, err := p.db.LookupMemoryAlias(c); err == nil {
			ids[id] = true
		} else if !errors.Is(err, sql.ErrNoRows) {
			return nil, fmt.Errorf("memory: focus: alias lookup %q: %w", c, err)
		}

		titleIDs, err := p.db.ListMemoryNodeIDsByTitleMatch(c)
		if err != nil {
			return nil, fmt.Errorf("memory: focus: title match %q: %w", c, err)
		}
		for _, id := range titleIDs {
			ids[id] = true
		}
	}
	return ids, nil
}

// sortedSet returns the set's members as a sorted slice — nil (not an empty
// slice) when the set is empty, so callers/tests can assert.Empty either way.
func sortedSet(m map[string]bool) []string {
	if len(m) == 0 {
		return nil
	}
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
