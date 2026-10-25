// Package learn reads Home's Learn cards out of the embedded user guide: each
// `<!-- learn` … `-->` block under a guide heading is one card (design
// 2026-10-19-home-zones-design.md §9). Load parses and validates them all;
// `watchtower guide learn --json` hands the result to the Desktop, and a Go
// test fails on any invalid card, so a broken card never ships.
package learn

import (
	"errors"
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strings"
	"unicode/utf8"

	"watchtower/docs/guide"
	"watchtower/internal/features"
)

// Card is one Learn card. The JSON keys are the `guide learn --json`
// contract the Desktop decodes; empty optional values are "" and an empty
// Replaces is [].
type Card struct {
	ID       string   `json:"id"`
	Title    string   `json:"title"`
	Text     string   `json:"text"`
	Area     string   `json:"area"`
	Level    string   `json:"level"`
	Kind     string   `json:"kind"`
	Since    string   `json:"since"`
	Action   string   `json:"action"`
	Changed  string   `json:"changed"`
	DoneWhen string   `json:"done_when"`
	Requires string   `json:"requires"`
	Replaces []string `json:"replaces"`
	// Page is the guide path ("features/home.md"), Anchor the section's
	// guide.Slug ("" for a card above the page's first heading).
	Page   string `json:"page"`
	Anchor string `json:"anchor"`
	// HotkeyLabel is the key a hotkey:<name> action shows ("⌘/"), else "".
	HotkeyLabel string `json:"hotkey_label"`
}

// Catalog is every card in guide order, and the retired ids: every id some
// card's replaces names, sorted. A retired id is never a card again.
type Catalog struct {
	Cards   []Card   `json:"cards"`
	Retired []string `json:"retired"`
}

// Rune limits (§9.2).
const (
	maxTitle  = 40
	maxText   = 120
	maxPrompt = 120
)

var (
	idPattern    = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)
	sincePattern = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)
	keyPattern   = regexp.MustCompile(`^[a-z_]+$`)
)

// requiredKeys and optionalKeys are the card's keys (§9.2).
var (
	requiredKeys = []string{"id", "title", "text", "area", "level", "kind", "since"}
	optionalKeys = []string{"action", "changed", "done_when", "requires", "replaces"}
)

// Load parses and validates every card of the embedded guide. The error
// joins every problem found, each naming its page and card.
func Load() (Catalog, error) {
	return load(guide.Pages())
}

func load(pages []guide.Page) (Catalog, error) {
	var errs []error
	cards := []Card{}
	for _, p := range pages {
		for _, s := range p.Sections {
			if guide.HasStrayCardOpen(s.Text) {
				errs = append(errs, fmt.Errorf("%s: a %q block under %q never closes with \"-->\"", p.Path, "<!-- learn", s.Heading))
			}
			for i, body := range s.Cards {
				c, cardErrs := parseCard(body)
				c.Page, c.Anchor = p.Path, s.Anchor
				name := fmt.Sprintf("card %d under %q", i+1, s.Heading)
				if c.ID != "" {
					name = fmt.Sprintf("card %q", c.ID)
				}
				for _, e := range append(cardErrs, validate(&c)...) {
					errs = append(errs, fmt.Errorf("%s: %s: %w", p.Path, name, e))
				}
				cards = append(cards, c)
			}
		}
	}
	retired := map[string]bool{}
	for _, c := range cards {
		for _, id := range c.Replaces {
			retired[id] = true
		}
	}
	firstPage := map[string]string{}
	for _, c := range cards {
		if c.ID == "" {
			continue
		}
		if prev, dup := firstPage[c.ID]; dup {
			errs = append(errs, fmt.Errorf("%s: card %q: id already used on %s", c.Page, c.ID, prev))
		} else {
			firstPage[c.ID] = c.Page
		}
		if retired[c.ID] {
			errs = append(errs, fmt.Errorf("%s: card %q: id is retired (another card replaces it): remove this card or give it a new id", c.Page, c.ID))
		}
	}
	cat := Catalog{Cards: cards, Retired: make([]string, 0, len(retired))}
	for id := range retired {
		cat.Retired = append(cat.Retired, id)
	}
	sort.Strings(cat.Retired)
	if len(errs) > 0 {
		return Catalog{}, errors.Join(errs...)
	}
	return cat, nil
}

// parseCard reads a block body of "key: value" lines (blank lines skipped).
// It fills what it can and reports unknown, duplicate, empty and missing keys.
func parseCard(body string) (Card, []error) {
	c := Card{Replaces: []string{}}
	var errs []error
	seen := map[string]bool{}
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		key, value, ok := strings.Cut(line, ":")
		key, value = strings.TrimSpace(key), strings.TrimSpace(value)
		if !ok || !keyPattern.MatchString(key) {
			errs = append(errs, fmt.Errorf("line %q is not \"key: value\"", line))
			continue
		}
		if !slices.Contains(requiredKeys, key) && !slices.Contains(optionalKeys, key) {
			errs = append(errs, fmt.Errorf("unknown key %q", key))
			continue
		}
		if seen[key] {
			errs = append(errs, fmt.Errorf("duplicate key %q", key))
			continue
		}
		seen[key] = true
		if value == "" {
			errs = append(errs, fmt.Errorf("key %q has no value", key))
			continue
		}
		if err := c.set(key, value); err != nil {
			errs = append(errs, err)
		}
	}
	for _, key := range requiredKeys {
		if !seen[key] {
			errs = append(errs, fmt.Errorf("missing required key %q", key))
		}
	}
	return c, errs
}

func (c *Card) set(key, value string) error {
	switch key {
	case "id":
		c.ID = value
	case "title":
		c.Title = value
	case "text":
		c.Text = value
	case "area":
		c.Area = value
	case "level":
		c.Level = value
	case "kind":
		c.Kind = value
	case "since":
		c.Since = value
	case "action":
		c.Action = value
	case "changed":
		c.Changed = value
	case "done_when":
		c.DoneWhen = value
	case "requires":
		c.Requires = value
	case "replaces":
		ids, err := parseList(value)
		if err != nil {
			return err
		}
		c.Replaces = ids
	}
	return nil
}

// parseList reads "[a, b]".
func parseList(value string) ([]string, error) {
	inner, ok := strings.CutPrefix(value, "[")
	if ok {
		inner, ok = strings.CutSuffix(inner, "]")
	}
	if !ok {
		return nil, fmt.Errorf("replaces %q is not a [id, id] list", value)
	}
	var ids []string
	for _, id := range strings.Split(inner, ",") {
		id = strings.TrimSpace(id)
		if id == "" {
			return nil, fmt.Errorf("replaces %q has an empty id", value)
		}
		ids = append(ids, id)
	}
	return ids, nil
}

// validate checks one parsed card's values (§9.2, §9.3, §9.7). A value left
// empty by a parse error is not reported twice.
func validate(c *Card) []error {
	var errs []error
	bad := func(format string, args ...any) { errs = append(errs, fmt.Errorf(format, args...)) }
	if c.ID != "" && !idPattern.MatchString(c.ID) {
		bad("id %q is not kebab-case", c.ID)
	}
	if n := utf8.RuneCountInString(c.Title); n > maxTitle {
		bad("title is %d characters (max %d)", n, maxTitle)
	}
	if n := utf8.RuneCountInString(c.Text); n > maxText {
		bad("text is %d characters (max %d)", n, maxText)
	}
	if n := utf8.RuneCountInString(c.Changed); n > maxText {
		bad("changed is %d characters (max %d)", n, maxText)
	}
	oneOf := func(key, value string, allowed []string) {
		if value != "" && !slices.Contains(allowed, value) {
			bad("%s %q is not one of %s", key, value, strings.Join(allowed, ", "))
		}
	}
	oneOf("area", c.Area, areas)
	oneOf("level", c.Level, levels)
	oneOf("kind", c.Kind, kinds)
	oneOf("done_when", c.DoneWhen, Signals)
	if c.Since != "" && c.Since != "next" && !sincePattern.MatchString(c.Since) {
		bad("since %q is not X.Y.Z or next", c.Since)
	}
	if c.Action != "" {
		label, err := checkAction(c.Action)
		if err != nil {
			errs = append(errs, err)
		}
		c.HotkeyLabel = label
	}
	if c.Requires != "" {
		if err := checkRequires(c.Requires); err != nil {
			errs = append(errs, err)
		}
	}
	if c.Changed != "" && len(c.Replaces) == 0 {
		bad("changed needs replaces")
	}
	for i, id := range c.Replaces {
		switch {
		case !idPattern.MatchString(id):
			bad("replaces id %q is not kebab-case", id)
		case id == c.ID:
			bad("replaces its own id")
		case slices.Contains(c.Replaces[:i], id):
			bad("replaces %q twice", id)
		}
	}
	return errs
}

// checkAction checks an action against its grammar and returns the hotkey
// label of a hotkey:<name> action.
func checkAction(action string) (string, error) {
	kind, arg, _ := strings.Cut(action, ":")
	if arg == "" {
		return "", fmt.Errorf("action %q has no value after its kind", action)
	}
	switch kind {
	case "nav":
		if !slices.Contains(navScreens, arg) {
			return "", fmt.Errorf("action %q: unknown screen (one of %s)", action, strings.Join(navScreens, ", "))
		}
	case "connect":
		if !slices.Contains(sources, arg) {
			return "", fmt.Errorf("action %q: unknown source (one of %s)", action, strings.Join(sources, ", "))
		}
	case "turnOn":
		f, ok := features.ByID(arg)
		if !ok {
			return "", fmt.Errorf("action %q: unknown feature id", action)
		}
		if f.ConfigKey == "" {
			return "", fmt.Errorf("action %q: feature %q has no switch", action, arg)
		}
	case "chat":
		if n := utf8.RuneCountInString(arg); n > maxPrompt {
			return "", fmt.Errorf("action %q: prompt is %d characters (max %d)", action, n, maxPrompt)
		}
	case "hotkey":
		label, ok := hotkeys[arg]
		if !ok {
			return "", fmt.Errorf("action %q: unknown hotkey name (add it to learn.hotkeys)", action)
		}
		return label, nil
	default:
		return "", fmt.Errorf("action %q: kind is not nav, connect, turnOn, chat or hotkey", action)
	}
	return "", nil
}

func checkRequires(req string) error {
	kind, arg, _ := strings.Cut(req, ":")
	switch kind {
	case "feature":
		if _, ok := features.ByID(arg); !ok {
			return fmt.Errorf("requires %q: unknown feature id", req)
		}
	case "source":
		if !slices.Contains(sources, arg) {
			return fmt.Errorf("requires %q: unknown source (one of %s)", req, strings.Join(sources, ", "))
		}
	default:
		return fmt.Errorf("requires %q is not feature:<id> or source:<name>", req)
	}
	return nil
}
