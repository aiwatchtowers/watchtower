// Package memory implements the secretary memory vault: markdown nodes with
// YAML frontmatter stored in a git repository, indexed into SQLite for search.
package memory

import (
	"bytes"
	"crypto/rand"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// Node is one vault page: authored frontmatter state plus the markdown body.
// Title is derived from the first H1 in Body; Render never writes it to
// frontmatter. Derived numbers (access counts, retention) live only in the
// SQLite index, never in files.
type Node struct {
	ID         string
	Type       string // entity | episode | rollup | belief
	Tier       string // short | long
	Status     string // active | closed | tombstone
	RedirectTo string // tombstones only
	Title      string // first H1 in Body, "" when absent
	Aliases    []string
	Refs       struct {
		PeopleCard int64
		Targets    []int64
	}
	Body string // markdown below the frontmatter, H1 included
}

// Link is one [[id]] or [[id|label]] wiki-link occurrence in a node body.
type Link struct {
	ID    string
	Label string // empty for label-less links
}

const fence = "---\n"

// frontmatter is the strict YAML schema between the --- fences. Unknown keys
// are rejected at parse time (schema discipline).
type frontmatter struct {
	ID         string    `yaml:"id"`
	Type       string    `yaml:"type"`
	Tier       string    `yaml:"tier"`
	Status     string    `yaml:"status"`
	RedirectTo string    `yaml:"redirect_to"`
	Aliases    []string  `yaml:"aliases"`
	Refs       *nodeRefs `yaml:"refs"`
}

type nodeRefs struct {
	PeopleCard int64   `yaml:"people_card"`
	Targets    []int64 `yaml:"targets"`
}

var (
	validTypes    = map[string]bool{"entity": true, "episode": true, "rollup": true, "belief": true}
	validTiers    = map[string]bool{"short": true, "long": true}
	validStatuses = map[string]bool{"active": true, "closed": true, "tombstone": true}

	wikiLinkRe = regexp.MustCompile(`\[\[([^\[\]|]+)(?:\|([^\[\]|]*))?\]\]`)
	h1Re       = regexp.MustCompile(`(?m)^# (.+)$`)
)

// ParseNode parses a vault file: YAML frontmatter between --- fences followed
// by a markdown body. Validation is strict — unknown frontmatter keys, missing
// id, or out-of-enum type/tier/status are errors.
func ParseNode(raw []byte) (Node, error) {
	rest, ok := bytes.CutPrefix(raw, []byte(fence))
	if !ok {
		return Node{}, fmt.Errorf("memory: node has no frontmatter opening fence")
	}
	fmBytes, body, ok := bytes.Cut(rest, []byte("\n"+fence))
	if !ok {
		return Node{}, fmt.Errorf("memory: node has no frontmatter closing fence")
	}

	dec := yaml.NewDecoder(bytes.NewReader(fmBytes))
	dec.KnownFields(true)
	var fm frontmatter
	if err := dec.Decode(&fm); err != nil {
		return Node{}, fmt.Errorf("memory: parse frontmatter: %w", err)
	}

	if fm.ID == "" {
		return Node{}, fmt.Errorf("memory: node has empty id")
	}
	if !validTypes[fm.Type] {
		return Node{}, fmt.Errorf("memory: node %s has invalid type %q", fm.ID, fm.Type)
	}
	if !validTiers[fm.Tier] {
		return Node{}, fmt.Errorf("memory: node %s has invalid tier %q", fm.ID, fm.Tier)
	}
	if !validStatuses[fm.Status] {
		return Node{}, fmt.Errorf("memory: node %s has invalid status %q", fm.ID, fm.Status)
	}
	if fm.RedirectTo != "" && fm.Status != "tombstone" {
		return Node{}, fmt.Errorf("memory: node %s has redirect_to but status %q (tombstones only)", fm.ID, fm.Status)
	}

	n := Node{
		ID:         fm.ID,
		Type:       fm.Type,
		Tier:       fm.Tier,
		Status:     fm.Status,
		RedirectTo: fm.RedirectTo,
		Aliases:    fm.Aliases,
		Body:       string(body),
	}
	if fm.Refs != nil {
		n.Refs.PeopleCard = fm.Refs.PeopleCard
		n.Refs.Targets = fm.Refs.Targets
	}
	if m := h1Re.FindStringSubmatch(n.Body); m != nil {
		n.Title = strings.TrimSpace(m[1])
	}
	return n, nil
}

// Render produces the canonical file form of the node. For any node parsed
// from disk or built with derived fields consistent (Title matching the first
// H1, nil slices for absent lists), ParseNode(n.Render()) == n.
func (n Node) Render() []byte {
	var b strings.Builder
	b.WriteString(fence)
	fmt.Fprintf(&b, "id: %s\n", n.ID)
	fmt.Fprintf(&b, "type: %s\n", n.Type)
	fmt.Fprintf(&b, "tier: %s\n", n.Tier)
	fmt.Fprintf(&b, "status: %s\n", n.Status)
	if n.RedirectTo != "" {
		fmt.Fprintf(&b, "redirect_to: %s\n", n.RedirectTo)
	}
	if len(n.Aliases) > 0 {
		quoted := make([]string, len(n.Aliases))
		for i, a := range n.Aliases {
			quoted[i] = strconv.Quote(a)
		}
		fmt.Fprintf(&b, "aliases: [%s]\n", strings.Join(quoted, ", "))
	}
	if n.Refs.PeopleCard != 0 || len(n.Refs.Targets) > 0 {
		b.WriteString("refs:\n")
		if n.Refs.PeopleCard != 0 {
			fmt.Fprintf(&b, "  people_card: %d\n", n.Refs.PeopleCard)
		}
		if len(n.Refs.Targets) > 0 {
			targets := make([]string, len(n.Refs.Targets))
			for i, id := range n.Refs.Targets {
				targets[i] = strconv.FormatInt(id, 10)
			}
			fmt.Fprintf(&b, "  targets: [%s]\n", strings.Join(targets, ", "))
		}
	}
	b.WriteString(fence)
	b.WriteString(n.Body)
	return []byte(b.String())
}

// Links returns every [[id]] / [[id|label]] wiki-link in the body, in order
// of occurrence, duplicates included.
func (n Node) Links() []Link {
	var links []Link
	for _, m := range wikiLinkRe.FindAllStringSubmatch(n.Body, -1) {
		links = append(links, Link{ID: m[1], Label: m[2]})
	}
	return links
}

// NewID mints a node ID for the given kind ("entity", "episode", "rollup",
// "belief"): type prefix + 26-char ULID, lexicographically sortable by
// creation time. Panics on an unknown kind (programmer error).
func NewID(kind string) string {
	var prefix string
	switch kind {
	case "entity":
		prefix = "ent_"
	case "episode":
		prefix = "ep_"
	case "rollup":
		prefix = "sum_"
	case "belief":
		prefix = "bel_"
	default:
		panic(fmt.Sprintf("memory: unknown node kind %q", kind))
	}
	return prefix + newULID(time.Now())
}

// crockfordAlphabet is the Crockford base32 alphabet used by ULID (no I, L,
// O, U); it preserves byte order, so ULID strings sort by timestamp.
const crockfordAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// newULID builds a standard ULID: 48-bit millisecond timestamp + 80 bits of
// crypto randomness, encoded as 26 Crockford base32 characters. Implemented
// locally to avoid a dependency — we only ever generate, never parse.
func newULID(now time.Time) string {
	var raw [16]byte
	ms := uint64(now.UnixMilli())
	raw[0] = byte(ms >> 40)
	raw[1] = byte(ms >> 32)
	raw[2] = byte(ms >> 24)
	raw[3] = byte(ms >> 16)
	raw[4] = byte(ms >> 8)
	raw[5] = byte(ms)
	if _, err := rand.Read(raw[6:]); err != nil {
		// crypto/rand.Read never fails on supported platforms.
		panic(fmt.Sprintf("memory: crypto/rand failed: %v", err))
	}

	// Encode 128 bits as 26 five-bit groups (130 bits), left-padded with two
	// zero bits — the standard ULID layout (first char is always 0-7).
	out := make([]byte, 26)
	for i := range out {
		var v byte
		for j := 0; j < 5; j++ {
			bit := i*5 + j - 2 // index into the 128-bit array
			v <<= 1
			if bit >= 0 && raw[bit/8]>>(7-bit%8)&1 == 1 {
				v |= 1
			}
		}
		out[i] = crockfordAlphabet[v]
	}
	return string(out)
}
