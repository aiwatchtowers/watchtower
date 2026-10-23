// Package watch is the "Watch for something" recipe: the Personal recipe a
// custom track runs as (trigger {sync: custom_tracks}, track:scan). The
// track's owner-editable watch instruction is the literal on the recipe's one
// `const instruction = <JSON>;` line; Start turns an existing custom track
// into its recipe and binds the two.
package watch

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// TemplateName is the template's slug, also the slug a rendered recipe is
// checked under.
const TemplateName = "watch-for-something"

// ErrNotTemplateShaped is a recipe without exactly one instruction line.
var ErrNotTemplateShaped = errors.New("the recipe is not shaped like the Watch for something template")

//go:embed template.md
var template string

const (
	namePlaceholder        = "{{NAME}}"
	instructionPlaceholder = "{{INSTRUCTION}}"
	instructionPrefix      = "const instruction = "
	instructionSuffix      = ";"
	// maxNameRunes is the recipe parser's name cap.
	maxNameRunes = 80
	// maxSlugRunes caps the text part of a watch recipe's file name.
	maxSlugRunes = 40
	defaultName  = "Watch for something"
)

// Render is the template with name (whitespace collapsed, capped to the
// parser's 80 runes) and instruction as JSON string literals. The result
// parses as a Personal recipe; Render refuses it otherwise.
func Render(name, instruction string) ([]byte, error) {
	name = strings.Join(strings.Fields(name), " ")
	if r := []rune(name); len(r) > maxNameRunes {
		name = strings.TrimSpace(string(r[:maxNameRunes]))
	}
	if name == "" {
		name = defaultName
	}
	out := strings.Replace(template, namePlaceholder, jsonString(name), 1)
	out = strings.Replace(out, instructionPlaceholder, jsonString(instruction), 1)
	if _, err := automations.ParseRecipe(TemplateName, []byte(out), automations.Scope{Kind: automations.ScopePersonal}); err != nil {
		return nil, fmt.Errorf("rendering the watch recipe: %w", err)
	}
	return []byte(out), nil
}

// Instruction is the string on recipe's one instruction line; false when
// there is not exactly one such line or its literal is not a JSON string.
func Instruction(recipe []byte) (string, bool) {
	lines := strings.Split(string(recipe), "\n")
	i, ok := instructionLine(lines)
	if !ok {
		return "", false
	}
	return decodeInstructionLine(lines[i])
}

// SetInstruction rewrites recipe's one instruction line to instruction and
// leaves every other byte as it was; ErrNotTemplateShaped when that line is
// not there exactly once.
func SetInstruction(recipe []byte, instruction string) ([]byte, error) {
	lines := strings.Split(string(recipe), "\n")
	i, ok := instructionLine(lines)
	if !ok {
		return nil, ErrNotTemplateShaped
	}
	cr := strings.HasSuffix(lines[i], "\r")
	lines[i] = instructionPrefix + jsonString(instruction) + instructionSuffix
	if cr {
		lines[i] += "\r"
	}
	return []byte(strings.Join(lines, "\n")), nil
}

// instructionLine is the index of the one line holding the instruction
// literal; false when there is none or more than one.
func instructionLine(lines []string) (int, bool) {
	found := -1
	for i, l := range lines {
		if !strings.HasPrefix(l, instructionPrefix) {
			continue
		}
		if _, ok := decodeInstructionLine(l); !ok || found >= 0 {
			return 0, false
		}
		found = i
	}
	return found, found >= 0
}

func decodeInstructionLine(line string) (string, bool) {
	line = strings.TrimSuffix(line, "\r")
	lit, ok := strings.CutPrefix(line, instructionPrefix)
	if !ok {
		return "", false
	}
	lit, ok = strings.CutSuffix(lit, instructionSuffix)
	if !ok || !strings.HasPrefix(lit, `"`) {
		return "", false
	}
	var s string
	if err := json.Unmarshal([]byte(lit), &s); err != nil {
		return "", false
	}
	return s, true
}

// jsonString is s as a JSON string literal. encoding/json escapes U+2028 and
// U+2029, so the literal is also a valid one-line JavaScript string, and its
// escapes are YAML double-quoted escapes too.
func jsonString(s string) string {
	b, err := json.Marshal(s)
	if err != nil { // a Go string always marshals
		panic(err)
	}
	return string(b)
}

// StartOptions tunes Start. Confirm records the owner's confirmation of the
// written recipe (the owner pressed Start Watching); Now is the clock, zero =
// time.Now.
type StartOptions struct {
	Confirm bool
	Now     time.Time
}

// Start makes custom track t a watch: it writes its recipe to
// <workspaceDir>/automations/watch-<id>-<slug>.md through the indexer, binds
// the track to it, carries the track's enabled over to the recipe and, with
// opts.Confirm, confirms it. A track already bound writes no file and returns
// its automation, confirming it first when opts.Confirm is set and it is not
// (a retry after a failed confirm). The track is re-read, so a stale t cannot bind twice.
func Start(ctx context.Context, d *db.DB, ix *automations.Indexer, workspaceDir string, t db.Track, opts StartOptions) (*db.Automation, error) {
	now := opts.Now
	if now.IsZero() {
		now = time.Now()
	}
	cur, err := d.GetTrackByID(t.ID)
	if err != nil {
		return nil, fmt.Errorf("starting the watch of track %d: %w", t.ID, err)
	}
	if cur.Origin != "custom" {
		return nil, fmt.Errorf("starting the watch of track %d: %w", t.ID, db.ErrNotCustomTrack)
	}
	if cur.AutomationID != 0 {
		return confirmBound(d, cur.AutomationID, opts.Confirm, now)
	}
	data, err := Render(cur.Text, startInstruction(*cur))
	if err != nil {
		return nil, fmt.Errorf("starting the watch of track %d: %w", t.ID, err)
	}
	dir, err := automations.CanonicalDir(automations.PersonalDir(workspaceDir))
	if err != nil {
		return nil, fmt.Errorf("starting the watch of track %d: %w", t.ID, err)
	}
	path := filepath.Join(dir, fileSlug(*cur)+".md")
	a, err := ix.WriteRecipe(ctx, automations.Scope{Kind: automations.ScopePersonal}, dir, path, data)
	if err != nil {
		return nil, fmt.Errorf("starting the watch of track %d: %w", t.ID, err)
	}
	// The recipe takes the track's enabled before the bind, which copies the
	// recipe's onto the track: the copy is then already right, and a failure
	// before the bind leaves nothing a retry would not redo.
	if err := d.SetAutomationEnabled(a.ID, cur.Enabled, now); err != nil {
		return nil, fmt.Errorf("starting the watch of track %d: %w", t.ID, err)
	}
	if err := d.BindWatchTrack(cur.ID, a.ID); err != nil {
		return nil, fmt.Errorf("starting the watch of track %d: %w", t.ID, err)
	}
	if opts.Confirm {
		if err := d.ConfirmAutomation(a.ID, a.ApprovalHash, now); err != nil {
			return nil, fmt.Errorf("starting the watch of track %d: %w", t.ID, err)
		}
	}
	return d.GetAutomation(a.ID)
}

// confirmBound returns bound automation id, confirming its current approval
// hash first when confirm is set and that hash is not the confirmed one.
func confirmBound(d *db.DB, id int64, confirm bool, now time.Time) (*db.Automation, error) {
	a, err := d.GetAutomation(id)
	if err != nil || !confirm || a.ConfirmedHash == a.ApprovalHash {
		return a, err
	}
	if err := d.ConfirmAutomation(id, a.ApprovalHash, now); err != nil {
		return nil, fmt.Errorf("confirming watch recipe %d: %w", id, err)
	}
	return d.GetAutomation(id)
}

// startInstruction is t's watch instruction, else its context, else its text.
func startInstruction(t db.Track) string {
	for _, s := range []string{t.Instruction, t.Context, t.Text} {
		if s = strings.TrimSpace(s); s != "" {
			return s
		}
	}
	return ""
}

// fileSlug is watch-<id>-<slug of t.Text, ≤ 40 runes>, or watch-<id> when the
// text has no ASCII letter or digit.
func fileSlug(t db.Track) string {
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(t.Text) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			if dash && b.Len() > 0 {
				b.WriteByte('-')
			}
			dash = false
			b.WriteRune(r)
			continue
		}
		dash = true
	}
	s := b.String()
	if len(s) > maxSlugRunes {
		s = strings.TrimRight(s[:maxSlugRunes], "-")
	}
	base := "watch-" + strconv.Itoa(t.ID)
	if s == "" {
		return base
	}
	return base + "-" + s
}
