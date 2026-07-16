package memory

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"

	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// rewriteSource is the WithSource routing tag for the strong-tier entity page
// rewrite. It is deliberately ABSENT from the light-tier switch in
// internal/digest/models.go / internal/codex/models.go, so it routes to the
// default (strong) model.
const rewriteSource = prompts.MemoryEntityRewrite

// rewriteStaggerDays is the entity page-rewrite cadence: each entity is rewritten
// at most once per this many days, its slot deterministically staggered by an id
// hash so a run never rewrites every page at once (v1 uses this stagger alone —
// the link-count trigger is a documented follow-up, per the plan's N=5 caveat).
const rewriteStaggerDays = 7

// rewriteResult is the strong-tier entity_rewrite reply: rewritten prose plus
// the provenance markers the model cites (validated the MEM-01 way — every
// marker must already appear in the supplied episodes or it is dropped).
type rewriteResult struct {
	What    string       `json:"what"`
	Current string       `json:"current"`
	Facts   []string     `json:"facts"`
	Markers []episodeRef `json:"markers"`
}

// RewriteEntityPages is the strong-tier entity page-rewrite step (MEM-01 +
// MEM-08). It selects entities due for a rewrite (a deterministic 7-day id-hash
// stagger AND at least one linked episode to rewrite from), and for each one
// asks the strong model to rewrite the page's ## What / ## Current / ## Facts
// from the linked episodes' stories. The model only proposes: every provenance
// marker it emits is re-validated against the supplied episodes (unknown markers
// dropped and counted), ## Links / ## Open loops are maintained mechanically
// (untouched byte-for-byte), and existing ## Facts bullets the model omits are
// preserved (owner-preservation — non-contradicted facts survive).
//
// All rewritten pages commit as one vault batch ("memory(rewrite): N pages") and
// mirror into the index. A per-entity generate/parse failure is isolated: it is
// logged and skipped, leaving that page byte-identical (no commit), the run
// continues with the next entity — the same spirit as a compose failure leaving
// situations untouched. maxEntities caps rewrites per run (<= 0 = unbounded).
// The pipeline gates the call behind memory.semantic.enabled (Task 11); this
// function itself is unconditional so it can be unit-tested directly.
func (p *Pipeline) RewriteEntityPages(ctx context.Context, maxEntities int, now time.Time) (rewritten int, usage *digest.Usage, err error) {
	if p.generator == nil {
		return 0, nil, nil
	}
	rows, err := p.db.ListMemoryNodes()
	if err != nil {
		return 0, nil, err
	}

	var (
		nodes []Node
		ids   []string
		acc   digest.Usage
		calls int
	)
	tmpl := p.getPrompt(prompts.MemoryEntityRewrite)
	for _, row := range rows {
		if maxEntities > 0 && rewritten >= maxEntities {
			break
		}
		if row.Type != "entity" || row.Status != "active" {
			continue
		}
		if !dueForRewrite(row.ID, now) {
			continue
		}
		page, rerr := p.vault.ReadNode(row.ID)
		if rerr != nil {
			p.logf("memory: rewrite: read %s: %v", row.ID, rerr)
			continue
		}
		episodes := p.linkedEpisodes(page)
		if len(episodes) == 0 {
			continue // nothing new to rewrite from (the link-count trigger, v1)
		}

		system, user := buildRewritePrompt(tmpl, p.Language, page, episodes)
		raw, u, _, gerr := p.generator.Generate(digest.WithSource(ctx, rewriteSource), system, user, "")
		calls++
		addUsage(&acc, u)
		if gerr != nil {
			p.logf("memory: rewrite %s: generate: %v", row.ID, gerr) // isolated — page untouched
			continue
		}
		res, perr := parseRewrite(raw)
		if perr != nil {
			p.logf("memory: rewrite %s: %v", row.ID, perr) // isolated — page untouched
			continue
		}

		inputSet := episodeRefSet(episodes)
		markers, dropped := validateMarkers(inputSet, res.Markers)
		if dropped > 0 {
			p.logf("memory: rewrite %s: markers_rejected=%d (MEM-01)", row.ID, dropped)
		}
		facts := mergeFacts(parseFactsBullets(page.Body), res.Facts)

		page.Body = rebuildEntityBody(page, res.What, res.Current, facts, markers)
		nodes = append(nodes, page)
		ids = append(ids, page.ID)
		rewritten++
	}

	if calls > 0 {
		usage = &acc
	}
	if len(nodes) == 0 {
		return 0, usage, nil
	}

	msg := CommitMsg{
		Op:      "rewrite",
		Summary: fmt.Sprintf("%d pages", len(nodes)),
		Cause:   "rewrite",
		NodeIDs: ids,
	}
	if _, err := p.vault.WriteNodes(nodes, msg); err != nil {
		return 0, usage, err
	}
	nowStr := time.Now().UTC().Format(time.RFC3339)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, n, nowStr); err != nil {
			p.logf("memory: index %s after rewrite: %v", n.ID, err)
		}
	}
	return rewritten, usage, nil
}

// linkedEpisodes reads the active episode nodes wiki-linked from an entity
// page's body (## Links), skipping links that do not resolve to an episode.
func (p *Pipeline) linkedEpisodes(page Node) []Node {
	seen := make(map[string]bool)
	var eps []Node
	for _, l := range page.Links() {
		if !strings.HasPrefix(l.ID, "ep_") || seen[l.ID] {
			continue
		}
		seen[l.ID] = true
		ep, err := p.vault.ReadNode(l.ID)
		if err != nil || ep.Type != "episode" {
			continue
		}
		eps = append(eps, ep)
	}
	return eps
}

// dueForRewrite reports whether the entity is due for a rewrite at now. Each
// entity fires at most once per rewriteStaggerDays, its slot (a day within the
// cycle) deterministically chosen by hashing the id modulo the 7*24h window, so
// runs spread rewrites across the week instead of all firing together. Pure and
// side-effect free (unit-tested).
func dueForRewrite(id string, now time.Time) bool {
	day := now.UTC().Unix() / 86400
	slot := rewriteStaggerOffset(id) / (24 * 3600) // 0..rewriteStaggerDays-1
	return day%rewriteStaggerDays == slot
}

// rewriteStaggerOffset maps an id to a deterministic offset in seconds within
// the 7*24h stagger window.
func rewriteStaggerOffset(id string) int64 {
	h := sha256.Sum256([]byte(id))
	return int64(binary.BigEndian.Uint64(h[:8]) % (rewriteStaggerDays * 24 * 3600))
}

var whatHeadingRe = regexp.MustCompile(`(?m)^## What[ \t]*$`)

// buildRewritePrompt renders the entity_rewrite call: the language directive
// fills the template's single %s slot; the user message carries the entity's
// current page, then each linked episode's Story/Outcome excerpts, then an
// (empty in v1) background line. It never opens with a "-"/"--" line (the
// claude-CLI argv gotcha guarded by TestBuildExtractPromptsNeverStartWithDash).
func buildRewritePrompt(tmpl, lang string, page Node, episodes []Node) (system, user string) {
	system = fmt.Sprintf(tmpl, prompts.Directive(lang))

	var b strings.Builder
	b.WriteString("Entity page:\n\n")
	b.WriteString(page.Body)
	b.WriteString("\n\nNew episodes:\n\n")
	for _, ep := range episodes {
		fmt.Fprintf(&b, "### %s\n", ep.Title)
		if s := sectionFirstLine(ep.Body, "## Story"); s != "" {
			fmt.Fprintf(&b, "Story: %s\n", s)
		}
		if o := sectionFirstLine(ep.Body, "## Outcome"); o != "" {
			fmt.Fprintf(&b, "Outcome: %s\n", o)
		}
		b.WriteString("\n")
	}
	b.WriteString("Background: \n")
	return system, b.String()
}

// parseRewrite parses the entity_rewrite reply: a JSON object tolerated bare or
// inside a ```json fence (mirrors parseExtract's tolerance).
func parseRewrite(raw string) (rewriteResult, error) {
	s := strings.TrimSpace(raw)
	s = strings.TrimPrefix(s, "```json")
	s = strings.TrimPrefix(s, "```")
	s = strings.TrimSuffix(s, "```")
	start := strings.Index(s, "{")
	end := strings.LastIndex(s, "}")
	if start < 0 || end < start {
		return rewriteResult{}, fmt.Errorf("memory: rewrite response has no JSON object")
	}
	var r rewriteResult
	if err := json.Unmarshal([]byte(s[start:end+1]), &r); err != nil {
		return rewriteResult{}, fmt.Errorf("memory: parse rewrite response: %w", err)
	}
	return r, nil
}

// episodeRefSet is the set of "<channel_id> <ts>" provenance keys across the
// episodes — the input set the model's markers are validated against (MEM-01).
func episodeRefSet(episodes []Node) map[string]bool {
	set := make(map[string]bool)
	for _, ep := range episodes {
		for _, r := range parseProvenance(ep.Body) {
			set[r.ChannelID+" "+r.TS] = true
		}
	}
	return set
}

// validateMarkers keeps only the markers whose (channel_id, ts) appears in the
// input set (copy-don't-invent, MEM-01); the rest are dropped and counted.
func validateMarkers(inputSet map[string]bool, markers []episodeRef) (kept []episodeRef, dropped int) {
	for _, m := range markers {
		if inputSet[m.ChannelID+" "+m.TS] {
			kept = append(kept, m)
		} else {
			dropped++
		}
	}
	return kept, dropped
}

// renderMarkers renders validated markers as a deterministic "C1 ts, C2 ts"
// provenance line.
func renderMarkers(markers []episodeRef) string {
	toks := make([]string, len(markers))
	for i, m := range markers {
		toks[i] = m.ChannelID + " " + m.TS
	}
	sort.Strings(toks)
	return strings.Join(toks, ", ")
}

// parseFactsBullets returns the existing "- " bullets of the ## Facts section.
func parseFactsBullets(body string) []string {
	var facts []string
	inFacts := false
	for _, line := range strings.Split(body, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "## ") {
			inFacts = trimmed == "## Facts"
			continue
		}
		if inFacts && strings.HasPrefix(trimmed, "- ") {
			facts = append(facts, strings.TrimSpace(strings.TrimPrefix(trimmed, "-")))
		}
	}
	return facts
}

// mergeFacts is the owner-preservation merge: the model's facts first (freshest
// framing), then any existing ## Facts bullet the model omitted — so a
// non-contradicted existing fact always survives (git preserves everything
// regardless; code makes no line-level promise beyond this).
func mergeFacts(existing, model []string) []string {
	seen := make(map[string]bool)
	var out []string
	for _, f := range append(append([]string{}, model...), existing...) {
		f = strings.TrimSpace(f)
		if f == "" || seen[f] {
			continue
		}
		seen[f] = true
		out = append(out, f)
	}
	return out
}

// rebuildEntityBody rewrites ONLY the ## What / ## Current / ## Facts sections,
// preserving the head (title, anything before ## What) and the tail (## Links
// onward — Links and Open loops) byte-for-byte: they are maintained mechanically
// and the model never touches them.
func rebuildEntityBody(page Node, what, current string, facts []string, markers []episodeRef) string {
	body := page.Body
	head := "# " + page.Title + "\n\n"
	if loc := whatHeadingRe.FindStringIndex(body); loc != nil {
		head = body[:loc[0]]
	}
	tail := ""
	if loc := linksHeadingRe.FindStringIndex(body); loc != nil {
		tail = body[loc[0]:]
	}

	var b strings.Builder
	b.WriteString(head)
	if !strings.HasSuffix(head, "\n") {
		b.WriteString("\n")
	}
	b.WriteString("## What\n")
	if w := strings.TrimSpace(what); w != "" {
		b.WriteString(w + "\n")
	}
	b.WriteString("\n## Current\n")
	if c := strings.TrimSpace(current); c != "" {
		b.WriteString(c + "\n")
	}
	if len(markers) > 0 {
		b.WriteString("\nProvenance: " + renderMarkers(markers) + "\n")
	}
	b.WriteString("\n## Facts\n")
	for _, f := range facts {
		b.WriteString("- " + f + "\n")
	}
	if tail != "" {
		b.WriteString("\n" + tail)
	}
	return b.String()
}

// sectionFirstLine returns the first non-empty line under the given "## X"
// heading, or "" when the section is absent or empty.
func sectionFirstLine(body, heading string) string {
	inSection := false
	for _, line := range strings.Split(body, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "## ") {
			inSection = trimmed == heading
			continue
		}
		if inSection && trimmed != "" {
			return trimmed
		}
	}
	return ""
}

// addUsage folds a per-call digest.Usage into an accumulator (nil-safe).
func addUsage(acc, u *digest.Usage) {
	if u == nil {
		return
	}
	acc.InputTokens += u.InputTokens
	acc.OutputTokens += u.OutputTokens
	acc.TotalAPITokens += u.TotalAPITokens
	if u.Model != "" {
		acc.Model = u.Model
	}
}
