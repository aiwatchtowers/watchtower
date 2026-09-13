package memory

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// The world map is two-tier (Phase 3):
//
//   - index.md — the mechanical, unbounded full listing (renderIndex), the
//     browsing surface. It is a vault-root file, so Reconcile (which only scans
//     vaultSubdirs) never indexes it, same as map.md.
//   - map.md — the strong-tier hot summary (renderMap), hard-capped at ~2 KB
//     code-side. MCP memory_map reads it. On a generator failure or when the
//     semantic tier is off, the previous committed map.md is kept (else a tiny
//     mechanical stub pointing at index.md is written) so memory_map always has
//     a target.
const (
	indexFileName = "index.md"
	// mapByteCap is the hard code-side budget for the strong map.md. The prompt
	// asks for brevity but cannot be trusted to obey a byte cap (the spec's
	// 56 KB-at-447-entities miss), so the render is truncated at a line boundary.
	mapByteCap = 2048
	// mapTopEntities bounds the entity candidate set fed to the strong render
	// (ranked by importance_score).
	mapTopEntities = 12
	// mapMaxBeliefs bounds the active beliefs fed to the strong render.
	mapMaxBeliefs = 12
)

// renderMapSource is the WithSource routing tag for the strong-tier map render;
// ABSENT from the light-tier switch, so it routes to the default (strong) model.
const renderMapSource = prompts.MemoryRenderMap

// mapOpenEpisodesCap bounds the "Recent open episodes" list in the renders.
const mapOpenEpisodesCap = 10

var (
	slackUserAliasRe    = regexp.MustCompile(`^[UW][A-Z0-9]{4,}$`)
	slackChannelAliasRe = regexp.MustCompile(`^[CDG][A-Z0-9]{4,}$`)
)

// mapEntry is one entity line in the mechanical index.
type mapEntry struct {
	id, title, what string
	importance      float64
}

// renderIndex is the mechanical full world listing (formerly renderMap): counts
// by type/tier, entities grouped people/channels/projects with one-line What
// excerpts, and the most recent open episodes — written to index.md. Committed
// via Vault.WriteFile (a byte-identical render adds no commit). Unbounded size is
// fine; the file is never injected into a prompt.
func (p *Pipeline) renderIndex(runID int64) error {
	rows, err := p.db.ListMemoryNodes()
	if err != nil {
		return err
	}

	counts := make(map[string]int) // "type/tier" → count, tombstones excluded
	var people, channels, other []mapEntry
	var open []db.MemoryNodeRow
	for _, row := range rows {
		if row.Status == "tombstone" {
			continue
		}
		counts[row.Type+"/"+row.Tier]++
		switch row.Type {
		case "entity":
			n, err := p.vault.ReadNode(row.ID)
			if err != nil {
				p.logf("memory: index: read %s: %v", row.ID, err)
				continue
			}
			e := mapEntry{id: row.ID, title: row.Title, what: whatExcerpt(n.Body), importance: row.ImportanceScore}
			switch classifyEntity(n) {
			case "people":
				people = append(people, e)
			case "channels":
				channels = append(channels, e)
			default:
				other = append(other, e)
			}
		case "episode":
			if row.Status == "active" {
				open = append(open, row)
			}
		}
	}
	for _, group := range [][]mapEntry{people, channels, other} {
		sort.Slice(group, func(a, b int) bool {
			ta, tb := strings.ToLower(group[a].title), strings.ToLower(group[b].title)
			if ta != tb {
				return ta < tb
			}
			return group[a].id < group[b].id
		})
	}
	// Node IDs are ULIDs — sorting by ID descending is newest-first.
	sort.Slice(open, func(a, b int) bool { return open[a].ID > open[b].ID })
	if len(open) > mapOpenEpisodesCap {
		open = open[:mapOpenEpisodesCap]
	}

	var b strings.Builder
	b.WriteString("# Memory Index\n\n## Counts\n")
	for _, typ := range []string{"entity", "episode", "rollup", "belief"} {
		short, long := counts[typ+"/short"], counts[typ+"/long"]
		fmt.Fprintf(&b, "- %s: %d (short %d, long %d)\n", typ, short+long, short, long)
	}
	writeMapSection(&b, "People", people)
	writeMapSection(&b, "Channels", channels)
	writeMapSection(&b, "Projects & other", other)
	b.WriteString("\n## Recent open episodes\n")
	if len(open) == 0 {
		b.WriteString("(none)\n")
	}
	for _, row := range open {
		fmt.Fprintf(&b, "- [[%s|%s]]\n", row.ID, linkLabel(row.Title))
	}

	msg := CommitMsg{Op: "index", Summary: "render world index", Cause: fmt.Sprintf("run:%d", runID)}
	_, err = p.vault.WriteFile(indexFileName, []byte(b.String()), msg)
	return err
}

// renderMap renders the strong-tier hot summary to map.md, hard-capped at
// mapByteCap. strong means the semantic tier is enabled AND the run is within
// its output budget; when it is false (or no generator), the map generator is
// NEVER called and the fallback runs. On a generator failure the previous
// committed map.md is kept. Returns the call's usage (nil when no AI call ran)
// so the pipeline can fold it into run accounting. Non-fatal by contract: a
// failed map render never fails the run and leaves the last good map in place.
func (p *Pipeline) renderMap(ctx context.Context, runID int64, strong bool) (*digest.Usage, error) {
	if strong && p.generator != nil {
		return p.renderStrongMap(ctx, runID)
	}
	return nil, p.fallbackMap(runID)
}

// renderStrongMap is the strong-tier arm of renderMap, change-gated on a
// fingerprint of the RENDERED PROMPT INPUT (see 00069).
//
// The write was already change-gated — Vault.WriteFile returns early on
// byte-identical content, so the vault git log under-reports how often this ran
// — but the AI CALL that produced those bytes was not gated at all: one strong
// render per daemon cycle, forever. The fingerprint closes that: when the input
// the model would see is byte-identical to the one the committed map.md was
// rendered from AND that file is still on disk, the call is skipped and map.md
// is left exactly as it is (no fallback write either — the committed map already
// IS that render). The file condition matters because the skip returns before
// any write: a matching fingerprint over a missing map.md would otherwise leave
// nothing to recreate it.
//
// The fingerprint is stamped on SUCCESS only, deliberately unlike the
// rewrite/reflect memos: a failed generate leaves the input unchanged, so the
// next cycle is a legitimate retry of a transient failure, and the failure path
// already degrades to the cheap mechanical map.
func (p *Pipeline) renderStrongMap(ctx context.Context, runID int64) (*digest.Usage, error) {
	system, user, err := p.mapCall()
	if err != nil {
		p.logf("memory: strong map render failed, keeping previous map.md: %v", err)
		return nil, p.fallbackMap(runID)
	}
	fingerprint := mapInputFingerprint(user)
	stored, serr := p.mapInputFingerprintStored()
	if serr != nil {
		p.logf("memory: map: read step state: %v", serr) // fail open: render rather than skip
	} else if stored != "" && stored == fingerprint && p.mapFileExists() {
		// Identical input — map.md is already this render. The file check is not
		// belt-and-braces: the skip returns before ANY write, so a matching
		// fingerprint over a MISSING map.md would leave nothing to recreate it.
		// That is reachable — `watchtower memory reset-to` rewinds the vault past
		// the map commit, and the owner can delete the file — and before the
		// fingerprint gate every strong cycle either rewrote map.md or fell
		// through to fallbackMap, whose os.Stat recreated it.
		return nil, nil
	}

	raw, usage, _, gerr := p.generator.Generate(digest.WithSource(ctx, renderMapSource), system, user, "")
	if gerr != nil {
		p.logf("memory: strong map render failed, keeping previous map.md: %v", fmt.Errorf("memory: render map: generate: %w", gerr))
		return usage, p.fallbackMap(runID)
	}
	msg := CommitMsg{Op: "map", Summary: "render hot map", Cause: fmt.Sprintf("run:%d", runID)}
	if _, werr := p.vault.WriteFile(mapFileName, []byte(capMapBytes(strings.TrimSpace(raw))), msg); werr != nil {
		return usage, werr
	}
	if err := p.db.SetMemoryStepState(db.MemoryStepMap, "", time.Now().UTC().Format(time.RFC3339), fingerprint); err != nil {
		p.logf("memory: map: stamp step state: %v", err) // costs repeats, never correctness
	}
	return usage, nil
}

// mapCall builds the strong map's prompt from the top entities (by importance),
// open episodes, and active beliefs — the exact bytes the fingerprint gate keys
// on, so the gate can never diverge from what the model would actually see.
func (p *Pipeline) mapCall() (system, user string, err error) {
	entities, open, beliefs, err := p.mapInputs()
	if err != nil {
		return "", "", err
	}
	system, user = buildRenderMapPrompt(p.getPrompt(prompts.MemoryRenderMap), p.Language, entities, open, beliefs)
	return system, user, nil
}

// mapInputFingerprint hashes the rendered user message. The system message is
// deliberately excluded: it is the prompt template, and a template edit should
// re-render on its own cadence, not be conflated with "the world changed".
func mapInputFingerprint(user string) string {
	sum := sha256.Sum256([]byte(user))
	return hex.EncodeToString(sum[:])
}

// mapInputFingerprintStored reads the fingerprint of the input map.md was last
// rendered from ("" when the strong map has never rendered).
func (p *Pipeline) mapInputFingerprintStored() (string, error) {
	_, fingerprint, err := p.db.MemoryStepState(db.MemoryStepMap, "")
	return fingerprint, err
}

// mapFileExists reports whether map.md is on disk — the fingerprint gate's
// second condition, since a skip writes nothing at all. A stat error other than
// "missing" also reads as absent, so the gate fails toward rendering.
func (p *Pipeline) mapFileExists() bool {
	_, err := os.Stat(filepath.Join(p.vault.path, mapFileName))
	return err == nil
}

// beliefEntry is one active belief line in the strong map input.
type beliefEntry struct {
	statement  string
	confidence float64
}

// mapInputs gathers the cheap retention-ordered inputs for the strong render:
// the top entities by importance with their ## Current excerpts, the newest open
// episodes, and the active beliefs with confidence.
func (p *Pipeline) mapInputs() (entities []mapEntry, open []string, beliefs []beliefEntry, err error) {
	rows, err := p.db.ListMemoryNodes()
	if err != nil {
		return nil, nil, nil, err
	}
	var (
		entries  []mapEntry
		openRows []db.MemoryNodeRow
	)
	for _, row := range rows {
		if row.Status == "tombstone" {
			continue
		}
		switch row.Type {
		case "entity":
			if row.Status != "active" {
				continue
			}
			n, rerr := p.vault.ReadNode(row.ID)
			if rerr != nil {
				p.logf("memory: map: read %s: %v", row.ID, rerr)
				continue
			}
			entries = append(entries, mapEntry{
				id:         row.ID,
				title:      row.Title,
				what:       sectionFirstLine(n.Body, "## Current"),
				importance: row.ImportanceScore,
			})
		case "episode":
			if row.Status == "active" {
				openRows = append(openRows, row)
			}
		case "belief":
			if row.Status != "active" {
				continue
			}
			n, rerr := p.vault.ReadNode(row.ID)
			if rerr != nil {
				continue
			}
			beliefs = append(beliefs, beliefEntry{statement: row.Title, confidence: n.Confidence})
		}
	}

	sort.Slice(entries, func(a, b int) bool {
		if entries[a].importance != entries[b].importance {
			return entries[a].importance > entries[b].importance
		}
		return entries[a].id < entries[b].id
	})
	for i, e := range entries {
		if i >= mapTopEntities {
			break
		}
		entities = append(entities, e)
	}

	sort.Slice(openRows, func(a, b int) bool { return openRows[a].ID > openRows[b].ID })
	for i, row := range openRows {
		if i >= mapOpenEpisodesCap {
			break
		}
		open = append(open, row.Title)
	}
	if len(beliefs) > mapMaxBeliefs {
		beliefs = beliefs[:mapMaxBeliefs]
	}
	return entities, open, beliefs, nil
}

// buildRenderMapPrompt renders the strong map call: the language directive fills
// the template's single %s slot; the user message lists the top entities, open
// episodes, and active beliefs. It never opens with a "-"/"--" line (the
// claude-CLI argv gotcha).
func buildRenderMapPrompt(tmpl, lang string, entities []mapEntry, open []string, beliefs []beliefEntry) (system, user string) {
	system = fmt.Sprintf(tmpl, prompts.Directive(lang))

	var b strings.Builder
	b.WriteString("Top entities:\n\n")
	for _, e := range entities {
		if e.what != "" {
			fmt.Fprintf(&b, "- %s: %s\n", e.title, e.what)
		} else {
			fmt.Fprintf(&b, "- %s\n", e.title)
		}
	}
	b.WriteString("\nOpen episodes:\n")
	for _, o := range open {
		fmt.Fprintf(&b, "- %s\n", o)
	}
	b.WriteString("\nActive beliefs:\n")
	for _, bel := range beliefs {
		fmt.Fprintf(&b, "- %s (confidence %.1f)\n", bel.statement, bel.confidence)
	}
	return system, b.String()
}

// capMapBytes enforces the mapByteCap hard budget: if the rendered map exceeds
// it, the map is truncated at the last line boundary that fits and a truncation
// note is appended, so the file stays under the cap and never ends mid-line.
func capMapBytes(s string) string {
	if len(s) <= mapByteCap {
		return s
	}
	const note = "\n\n_(truncated — see index.md)_\n"
	budget := mapByteCap - len(note)
	if budget < 0 {
		budget = 0
	}
	cut := s[:budget]
	if i := strings.LastIndexByte(cut, '\n'); i >= 0 {
		cut = cut[:i]
	}
	// UTF-8 safety: if the byte cut landed inside a multibyte rune (no newline to
	// snap to), back up over the partial trailing bytes so we never emit a split
	// rune. A legitimately-encoded U+FFFD (size 3) is left intact.
	for len(cut) > 0 {
		if r, size := utf8.DecodeLastRuneInString(cut); r != utf8.RuneError || size > 1 {
			break
		}
		cut = cut[:len(cut)-1]
	}
	return cut + note
}

// fallbackMap keeps the previous committed map.md when one exists; otherwise it
// writes a tiny mechanical stub pointing at index.md so memory_map always has a
// target. Used when the semantic tier is off or the strong render failed.
func (p *Pipeline) fallbackMap(runID int64) error {
	if p.mapFileExists() {
		return nil // keep the previous committed map.md
	}
	content := "# World map\n\nSee `index.md` for the full memory index.\n"
	msg := CommitMsg{Op: "map", Summary: "hot map stub", Cause: fmt.Sprintf("run:%d", runID)}
	_, err := p.vault.WriteFile(mapFileName, []byte(content), msg)
	return err
}

func writeMapSection(b *strings.Builder, heading string, entries []mapEntry) {
	fmt.Fprintf(b, "\n## %s\n", heading)
	if len(entries) == 0 {
		b.WriteString("(none)\n")
		return
	}
	for _, e := range entries {
		fmt.Fprintf(b, "- [[%s|%s]]", e.id, linkLabel(e.title))
		if e.what != "" {
			b.WriteString(" — " + e.what)
		}
		if e.importance != 0 {
			fmt.Fprintf(b, " (importance %.1f)", e.importance)
		}
		b.WriteString("\n")
	}
}

// classifyEntity buckets an entity page for the index by its natural-key
// aliases: Slack user IDs / emails / people-card refs → people, Slack
// channel-ish IDs or a "#name" title → channels, everything else (Jira
// project keys, hand-made pages) → other.
func classifyEntity(n Node) string {
	if n.Refs.PeopleCard != 0 {
		return "people"
	}
	for _, a := range n.Aliases {
		if slackUserAliasRe.MatchString(a) || strings.Contains(a, "@") {
			return "people"
		}
	}
	if strings.HasPrefix(n.Title, "#") {
		return "channels"
	}
	for _, a := range n.Aliases {
		if slackChannelAliasRe.MatchString(a) {
			return "channels"
		}
	}
	return "other"
}

// whatExcerpt returns the first non-empty line of the "## What" section,
// truncated for the one-line index render.
func whatExcerpt(body string) string {
	line := sectionFirstLine(body, "## What")
	if r := []rune(line); len(r) > 120 {
		return string(r[:120]) + "…"
	}
	return line
}
