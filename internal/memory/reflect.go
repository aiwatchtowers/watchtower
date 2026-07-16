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

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// reflectSource is the WithSource routing tag for the strong-tier weekly
// reflection pass. It is deliberately ABSENT from the light-tier switch in
// internal/digest/models.go / internal/codex/models.go, so it routes to the
// default (strong) model — a models test pins this (mirror of the Phase-3
// rewrite/beliefs routing).
const reflectSource = prompts.MemoryReflect

// reflectStaggerDays is the reflection cadence: the pass fires on at most one
// day per this many, its slot deterministically chosen from the workspace id
// (mirror rewriteStaggerDays) so no per-workspace watermark column is needed.
const reflectStaggerDays = 7

// reflectWindowDays is the git-log lookback the churn digest is built over.
const reflectWindowDays = 7

// reflectMaxObservations caps the meta-observations applied per run (design
// spec §5: at most three).
const reflectMaxObservations = 3

// reflectChurnThreshold is the number of in-window machine commits touching a
// node before it counts as "flapping" — the code-side guard on the model's
// observations (a dispute/note is applied only for a node this unstable, so the
// model cannot flag a calm belief/entity). A code constant like the retention
// math, not config.
const reflectChurnThreshold = 3

var currentHeadingRe = regexp.MustCompile(`(?m)^## Current[ \t]*$`)

// reflectObservation is one meta-observation the model proposes over the churn
// digest. The model only names an unstable node and its kind; the code disposes
// (SetDisputePending for a belief, a ## Current note for an entity). The model
// never sets confidence/status (MEM-11).
type reflectObservation struct {
	Kind      string `json:"kind"`      // "dispute" (belief) | "note" (entity)
	NodeID    string `json:"node_id"`   // belief/entity id, validated against the churn set
	Note      string `json:"note"`      // ## Current bullet text (note only)
	Rationale string `json:"rationale"` // one-line reason, stored as the dispute reason / note context
}

type reflectReply struct {
	Observations []reflectObservation `json:"observations"`
}

// nodeChurn accumulates one node's in-window commit activity: how many machine
// commits touched it and the per-op breakdown, plus (for beliefs) how many
// ## History entries landed in the window.
type nodeChurn struct {
	commits      int
	byOp         map[string]int
	historyLines int
}

// Reflect is the strong-tier weekly reflection pass (Phase-4 surface, MEM-11).
// It runs at most once per reflectStaggerDays via a deterministic stagger keyed
// on the workspace id, reads the vault git-log churn over the last week plus
// per-belief ## History churn, and asks the strong model for up to three
// meta-observations naming the unstable areas. Each observation is disposed of
// BY CODE ONLY: a "dispute" on a flapping belief sets a dispute_pending flag
// (surfaced later by the inbox watchtower detector — MEM-05/10), a "note" on a
// flapping entity appends a dated bullet to its ## Current section (an ordinary
// memory(reflect) vault commit, mirrored to the index). Reflection NEVER
// mutates a belief's confidence/status/stability directly (MEM-11) — the only
// belief-side write is the side-table dispute flag.
//
// The design spec's third disposition (a "briefing journal line") is realized
// indirectly, not by a reflection write: a dispute flag leads the belief pass
// to shake the belief, and the briefing revision journal (gatherMemoryRevisions)
// then surfaces that change from the belief's ## History. Reflection itself
// writes only dispute flags and entity ## Current notes, keeping the MEM-11
// guard simple.
//
// Isolation: a generate/parse failure returns an error but never mutates a
// belief or entity (the caller logs it and the run continues). n is the number
// of observations applied; flagged is the subset that set a dispute flag;
// dropped counts observations the code refused (invented/calm node,
// sub-threshold churn, wrong kind for the node type, unknown kind) — surfaced in
// the run-done log so systematic model misbehaviour is visible (P6). When not
// due, or when the generator is nil, it is a clean no-op.
func (p *Pipeline) Reflect(ctx context.Context, now time.Time) (n, flagged, dropped int, usage *digest.Usage, err error) {
	if p.generator == nil {
		return 0, 0, 0, nil, nil
	}
	if !dueForReflect(p.workspaceStaggerKey(), now) {
		return 0, 0, 0, nil, nil // not this workspace's weekly slot
	}

	rows, err := p.db.ListMemoryNodes()
	if err != nil {
		return 0, 0, 0, nil, err
	}
	since := now.AddDate(0, 0, -reflectWindowDays)
	commits, err := p.vault.LogMemoryCommits(since)
	if err != nil {
		return 0, 0, 0, nil, err
	}

	churn := p.reflectChurn(rows, commits, since)
	if len(churn) == 0 {
		return 0, 0, 0, nil, nil // a calm week — no AI call at all
	}

	typeByID := make(map[string]string, len(rows))
	for _, r := range rows {
		typeByID[r.ID] = r.Type
	}

	system, user := buildReflectPrompt(p.getPrompt(prompts.MemoryReflect), p.Language, rows, churn, since)
	raw, u, _, gerr := p.generator.Generate(digest.WithSource(ctx, reflectSource), system, user, "")
	usage = u
	if gerr != nil {
		return 0, 0, 0, usage, fmt.Errorf("memory: reflect: generate: %w", gerr)
	}
	reply, perr := parseReflect(raw)
	if perr != nil {
		return 0, 0, 0, usage, perr
	}

	var (
		noteNodes []Node
		noteIDs   []string
	)
	for _, obs := range reply.Observations {
		if n >= reflectMaxObservations {
			break
		}
		nodeType, ok := typeByID[obs.NodeID]
		if !ok || churn[obs.NodeID].commits < reflectChurnThreshold {
			p.logf("memory: reflect: observation %q dropped (id not in churn set or below threshold)", obs.NodeID)
			dropped++
			continue // invented/calm node — copy-don't-invent, code-side flapping guard
		}
		switch obs.Kind {
		case "dispute":
			if nodeType != "belief" {
				p.logf("memory: reflect: dispute observation on non-belief %s dropped", obs.NodeID)
				dropped++
				continue
			}
			if serr := p.db.SetDisputePending(obs.NodeID, reflectDisputeReason(obs.Rationale)); serr != nil {
				p.logf("memory: reflect: set dispute %s: %v", obs.NodeID, serr) // isolated: keep applying
				continue
			}
			flagged++
			n++
		case "note":
			if nodeType != "entity" {
				p.logf("memory: reflect: note observation on non-entity %s dropped", obs.NodeID)
				dropped++
				continue
			}
			node, nerr := p.applyReflectNote(obs, now)
			if nerr != nil {
				p.logf("memory: reflect: note %s: %v", obs.NodeID, nerr) // isolated
				continue
			}
			noteNodes = append(noteNodes, node)
			noteIDs = append(noteIDs, node.ID)
			n++
		default:
			p.logf("memory: reflect: unknown observation kind %q dropped", obs.Kind)
			dropped++
		}
	}

	if len(noteNodes) > 0 {
		msg := CommitMsg{Op: "reflect", Summary: fmt.Sprintf("%d entity notes", len(noteNodes)), Cause: "reflect", NodeIDs: noteIDs}
		if _, werr := p.vault.WriteNodes(noteNodes, msg); werr != nil {
			return n, flagged, dropped, usage, werr
		}
		nowStr := time.Now().UTC().Format(time.RFC3339)
		for _, nd := range noteNodes {
			if ierr := upsertIndexNode(p.db, nd, nowStr); ierr != nil {
				return n, flagged, dropped, usage, ierr // reconcile self-heals next run
			}
		}
	}
	return n, flagged, dropped, usage, nil
}

// applyReflectNote appends a dated "## Current" bullet to an entity page,
// recording the reflection observation as durable, model-mediated context. It
// never touches any belief (MEM-11) — the write is confined to the entity's
// ## Current section.
func (p *Pipeline) applyReflectNote(obs reflectObservation, now time.Time) (Node, error) {
	node, err := p.vault.ReadNode(obs.NodeID)
	if err != nil {
		return Node{}, err
	}
	text := strings.Join(strings.Fields(obs.Note), " ")
	if text == "" {
		text = strings.Join(strings.Fields(obs.Rationale), " ")
	}
	if text == "" {
		return Node{}, fmt.Errorf("empty note")
	}
	line := fmt.Sprintf("- %s: %s\n", now.UTC().Format("2006-01-02"), text)
	node.Body = appendToSection(node.Body, currentHeadingRe, "## Current", line)
	return node, nil
}

// reflectChurn folds the in-window commits into per-node activity, keeping only
// live beliefs/entities whose commit count reaches the flapping threshold — the
// candidate set shown to the model and validated against on apply. Belief
// ## History churn is counted from the index-backing vault body.
func (p *Pipeline) reflectChurn(rows []db.MemoryNodeRow, commits []MemoryCommit, since time.Time) map[string]nodeChurn {
	typeByID := make(map[string]string, len(rows))
	for _, r := range rows {
		if r.Status == "tombstone" {
			continue
		}
		typeByID[r.ID] = r.Type
	}

	raw := make(map[string]*nodeChurn)
	for _, c := range commits {
		for _, id := range c.NodeIDs {
			typ, live := typeByID[id]
			if !live || (typ != "belief" && typ != "entity") {
				continue
			}
			nc := raw[id]
			if nc == nil {
				nc = &nodeChurn{byOp: map[string]int{}}
				raw[id] = nc
			}
			nc.commits++
			nc.byOp[c.Op]++
		}
	}

	churn := make(map[string]nodeChurn)
	for id, nc := range raw {
		if nc.commits < reflectChurnThreshold {
			continue
		}
		if typeByID[id] == "belief" {
			if node, err := p.vault.ReadNode(id); err == nil {
				nc.historyLines = historyChurnSince(node.Body, since)
			}
		}
		churn[id] = *nc
	}
	return churn
}

// historyChurnSince counts a belief's "## History" bullets dated on or after
// since (date comparison is day-granular via lexical YYYY-MM-DD ordering). It
// shares the one ParseHistory reader with the briefing journal.
func historyChurnSince(body string, since time.Time) int {
	sinceDate := since.UTC().Format("2006-01-02")
	n := 0
	for _, b := range ParseHistory(body) {
		if b.Date >= sinceDate {
			n++
		}
	}
	return n
}

// buildReflectPrompt renders the reflection call: the language directive fills
// the template's single %s slot; the user message is a churn digest listing the
// flapping beliefs (with their statements + history churn) and entities (with
// their titles + commit breakdown). It never opens with a "-"/"--" line (the
// claude-CLI argv gotcha).
func buildReflectPrompt(tmpl, lang string, rows []db.MemoryNodeRow, churn map[string]nodeChurn, since time.Time) (system, user string) {
	system = fmt.Sprintf(tmpl, prompts.Directive(lang))

	titleByID := make(map[string]string, len(rows))
	typeByID := make(map[string]string, len(rows))
	for _, r := range rows {
		titleByID[r.ID] = r.Title
		typeByID[r.ID] = r.Type
	}
	ids := make([]string, 0, len(churn))
	for id := range churn {
		ids = append(ids, id)
	}
	sort.Strings(ids) // deterministic prompt order

	var beliefs, entities strings.Builder
	for _, id := range ids {
		nc := churn[id]
		title := strings.TrimSpace(titleByID[id])
		if title == "" {
			title = id
		}
		if typeByID[id] == "belief" {
			fmt.Fprintf(&beliefs, "- %s %q: %d revisions, %d history entries this week\n", id, title, nc.commits, nc.historyLines)
		} else {
			fmt.Fprintf(&entities, "- %s %q: %d page revisions this week (%s)\n", id, title, nc.commits, opBreakdown(nc.byOp))
		}
	}

	var b strings.Builder
	b.WriteString("Memory activity over the last seven days.\n\n")
	b.WriteString("Beliefs revised:\n")
	if beliefs.Len() == 0 {
		b.WriteString("(none)\n")
	} else {
		b.WriteString(beliefs.String())
	}
	b.WriteString("\nEntity pages revised:\n")
	if entities.Len() == 0 {
		b.WriteString("(none)\n")
	} else {
		b.WriteString(entities.String())
	}
	return system, b.String()
}

// opBreakdown renders a node's per-op commit counts as a stable "beliefs x2,
// rewrite x1" clause for the prompt.
func opBreakdown(byOp map[string]int) string {
	ops := make([]string, 0, len(byOp))
	for op := range byOp {
		ops = append(ops, op)
	}
	sort.Strings(ops)
	parts := make([]string, len(ops))
	for i, op := range ops {
		parts[i] = fmt.Sprintf("%s x%d", op, byOp[op])
	}
	return strings.Join(parts, ", ")
}

// parseReflect parses the reflection reply: a JSON object with an
// "observations" array, tolerated bare or inside a ```json fence.
func parseReflect(raw string) (reflectReply, error) {
	s := strings.TrimSpace(raw)
	s = strings.TrimPrefix(s, "```json")
	s = strings.TrimPrefix(s, "```")
	s = strings.TrimSuffix(s, "```")
	start := strings.Index(s, "{")
	end := strings.LastIndex(s, "}")
	if start < 0 || end < start {
		return reflectReply{}, fmt.Errorf("memory: reflect response has no JSON object")
	}
	var r reflectReply
	if err := json.Unmarshal([]byte(s[start:end+1]), &r); err != nil {
		return reflectReply{}, fmt.Errorf("memory: parse reflect response: %w", err)
	}
	return r, nil
}

// reflectDisputeReason renders the dispute-flag reason stored for a reflection
// observation, defaulting to a fixed phrase when the model gave no rationale.
func reflectDisputeReason(rationale string) string {
	r := strings.Join(strings.Fields(rationale), " ")
	if r == "" {
		return "reflection: belief evidence keeps conflicting"
	}
	return "reflection: " + r
}

// dueForReflect reports whether the reflection pass is due at now for the given
// workspace stagger key. Fires on at most one day per reflectStaggerDays, the
// slot deterministically chosen by hashing the key (mirror dueForRewrite). Pure
// and side-effect free (unit-tested).
func dueForReflect(key string, now time.Time) bool {
	day := now.UTC().Unix() / 86400
	slot := reflectStaggerOffset(key) / (24 * 3600) // 0..reflectStaggerDays-1
	return day%reflectStaggerDays == slot
}

// reflectStaggerOffset maps a workspace key to a deterministic offset in seconds
// within the stagger window. Namespaced ("reflect:") so a workspace's reflection
// slot is independent of any entity id sharing its bytes with dueForRewrite.
func reflectStaggerOffset(key string) int64 {
	h := sha256.Sum256([]byte("reflect:" + key))
	return int64(binary.BigEndian.Uint64(h[:8]) % (reflectStaggerDays * 24 * 3600))
}

// workspaceStaggerKey returns the reflection stagger key: the workspace id, or
// "" when no workspace row exists yet (still deterministic — a headless setup
// gets one stable slot).
func (p *Pipeline) workspaceStaggerKey() string {
	ws, err := p.db.GetWorkspace()
	if err != nil || ws == nil {
		return ""
	}
	return ws.ID
}
