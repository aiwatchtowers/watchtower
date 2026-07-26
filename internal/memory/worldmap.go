package memory

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
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
	// (ranked by links-in, a cheap importance proxy).
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
		content, usage, err := p.strongMapContent(ctx)
		if err != nil {
			p.logf("memory: strong map render failed, keeping previous map.md: %v", err)
			return usage, p.fallbackMap(runID)
		}
		msg := CommitMsg{Op: "map", Summary: "render hot map", Cause: fmt.Sprintf("run:%d", runID)}
		_, werr := p.vault.WriteFile(mapFileName, []byte(capMapBytes(content)), msg)
		return usage, werr
	}
	return nil, p.fallbackMap(runID)
}

// strongMapContent asks the strong model for the hot summary from the top
// entities (by links-in), open episodes, and active beliefs.
func (p *Pipeline) strongMapContent(ctx context.Context) (string, *digest.Usage, error) {
	entities, open, beliefs, err := p.mapInputs()
	if err != nil {
		return "", nil, err
	}
	system, user := buildRenderMapPrompt(p.getPrompt(prompts.MemoryRenderMap), p.Language, entities, open, beliefs)
	raw, usage, _, err := p.generator.Generate(digest.WithSource(ctx, renderMapSource), system, user, "")
	if err != nil {
		return "", usage, fmt.Errorf("memory: render map: generate: %w", err)
	}
	return strings.TrimSpace(raw), usage, nil
}

// beliefEntry is one active belief line in the strong map input.
type beliefEntry struct {
	statement  string
	confidence float64
}

// mapInputs gathers the cheap retention-ordered inputs for the strong render:
// the top entities by links-in with their ## Current excerpts, the newest open
// episodes, and the active beliefs with confidence.
func (p *Pipeline) mapInputs() (entities []mapEntry, open []string, beliefs []beliefEntry, err error) {
	rows, err := p.db.ListMemoryNodes()
	if err != nil {
		return nil, nil, nil, err
	}
	var (
		entries  []mapEntry
		entIDs   []string
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
			entries = append(entries, mapEntry{id: row.ID, title: row.Title, what: sectionFirstLine(n.Body, "## Current")})
			entIDs = append(entIDs, row.ID)
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

	// One grouped links-in query for every entity (avoids the per-entity N+1).
	linkCounts, err := p.db.CountMemoryLinksInBulk(entIDs)
	if err != nil {
		return nil, nil, nil, err
	}
	type ranked struct {
		e     mapEntry
		links int
	}
	cand := make([]ranked, len(entries))
	for i, e := range entries {
		cand[i] = ranked{e, linkCounts[e.id]}
	}

	sort.Slice(cand, func(a, b int) bool {
		if cand[a].links != cand[b].links {
			return cand[a].links > cand[b].links
		}
		return cand[a].e.id < cand[b].e.id
	})
	for i, c := range cand {
		if i >= mapTopEntities {
			break
		}
		entities = append(entities, c.e)
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
	if _, err := os.Stat(filepath.Join(p.vault.path, mapFileName)); err == nil {
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
