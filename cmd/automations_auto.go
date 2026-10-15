package cmd

import (
	"errors"
	"fmt"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// automationAutoJSON is `automations auto --json`: auto is the grant's state
// after the command, changed whether the command wrote or removed a row.
type automationAutoJSON struct {
	AutomationID int64  `json:"automation_id"`
	Tool         string `json:"tool"`
	Auto         bool   `json:"auto"`
	Changed      bool   `json:"changed"`
}

// automationGrantJSON is one grant in `show --json` and `list --json`.
type automationGrantJSON struct {
	Tool      string    `json:"tool"`
	Active    bool      `json:"active"`
	GrantedAt time.Time `json:"granted_at"`
}

// newAutomationGrantsJSON converts grant rows; never nil (the Desktop reads
// an empty list as []).
func newAutomationGrantsJSON(gs []db.AutomationToolGrant) []automationGrantJSON {
	out := make([]automationGrantJSON, 0, len(gs))
	for _, g := range gs {
		out = append(out, automationGrantJSON{Tool: g.Tool, Active: g.Active, GrantedAt: g.GrantedAt})
	}
	return out
}

// anyGrantPaused reports whether some grant is inactive (its hash is not the
// current approval hash): `list`'s auto_paused.
func anyGrantPaused(gs []automationGrantJSON) bool {
	for _, g := range gs {
		if !g.Active {
			return true
		}
	}
	return false
}

// runAutomationsAuto turns the per-(automation, tool) auto grant on or off
// (spec §6.4, §10). `on` is owner-only (AGENT-07) and bound to the current
// approval hash; `off` is open to anyone and idempotent.
func runAutomationsAuto(cmd *cobra.Command, args []string) error {
	switch args[2] {
	case "on":
		return automationsAutoOn(cmd, args[0], args[1])
	case "off":
		return automationsAutoOff(cmd, args[0], args[1])
	}
	return fmt.Errorf("invalid state %q: want \"on\" or \"off\"", args[2])
}

// automationsAutoOn checks, in order: AGENT-07 markers → --hash given →
// the automation exists → --hash is its current approval hash → it parses → the tool exists → not AlwaysAsk (D14)
// → the manifest admits it as a write → the store's hash check.
func automationsAutoOn(cmd *cobra.Command, arg, toolName string) error {
	if err := refuseUnderAgent("turn on auto for an automation's tool"); err != nil {
		return err
	}
	if autoFlags.Hash == "" {
		return errors.New("--hash is required: the approval hash you reviewed (see `watchtower automations show`)")
	}
	cfg, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	a, err := resolveAutomation(database, arg, autoFlags.Workbench)
	if err != nil {
		return err
	}
	// The manifest checked below must be the one --hash pins: a recipe
	// edited since the owner reviewed it is refused before it is parsed.
	// SetAutomationToolGrant re-checks the hash in its own transaction.
	if a.ApprovalHash != autoFlags.Hash {
		return fmt.Errorf("the recipe changed; reload and confirm again (`watchtower automations show %d`): %w",
			a.ID, db.ErrHashMismatch)
	}
	m, err := automationManifest(a)
	if err != nil {
		return err
	}
	t, ok := buildAutomationRegistry(cfg, database).Get(toolName)
	if !ok {
		return fmt.Errorf("unknown tool %q (see `watchtower actions tools`)", toolName)
	}
	if t.AlwaysAsk {
		return fmt.Errorf("%s always asks the owner and is never auto (D14)", t.Name)
	}
	if !m.AdmitsWrite(t) {
		return fmt.Errorf("automation #%d's permissions and outputs do not admit %s as a write; "+
			"add its permission to the recipe, confirm it, then turn auto on", a.ID, t.Name)
	}
	if err := database.SetAutomationToolGrant(a.ID, t.Name, autoFlags.Hash, time.Now()); err != nil {
		if errors.Is(err, db.ErrHashMismatch) {
			return fmt.Errorf("the recipe changed; reload and confirm again (`watchtower automations show %d`): %w", a.ID, err)
		}
		return err
	}
	return writeAutomationAuto(cmd, automationAutoJSON{AutomationID: a.ID, Tool: t.Name, Auto: true, Changed: true})
}

// automationManifest parses the indexed recipe's manifest; a parse-error row
// admits nothing.
func automationManifest(a *db.Automation) (*automations.Manifest, error) {
	if a.ParseError != "" {
		return nil, fmt.Errorf("automation #%d does not parse (%s); fix the recipe first", a.ID, a.ParseError)
	}
	r, err := automations.ParseRecipe(a.Slug, []byte(a.RecipeText), automationScopeOf(a))
	if err != nil {
		return nil, fmt.Errorf("automation #%d: re-parsing its indexed recipe (run `watchtower automations rescan`): %w", a.ID, err)
	}
	m, err := automations.ParseManifest(r.Permissions, r.Outputs, r.Scope)
	if err != nil {
		return nil, fmt.Errorf("automation #%d: %w", a.ID, err)
	}
	return m, nil
}

// automationsAutoOff removes the grant; no grant is not an error. The tool
// name is not checked against the registry, so a grant of a tool that no
// longer exists can still be removed.
func automationsAutoOff(cmd *cobra.Command, arg, toolName string) error {
	_, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	a, err := resolveAutomation(database, arg, autoFlags.Workbench)
	if err != nil {
		return err
	}
	removed, err := database.DeleteAutomationToolGrant(a.ID, toolName)
	if err != nil {
		return err
	}
	return writeAutomationAuto(cmd, automationAutoJSON{AutomationID: a.ID, Tool: toolName, Changed: removed})
}

func writeAutomationAuto(cmd *cobra.Command, j automationAutoJSON) error {
	w := cmd.OutOrStdout()
	if autoFlags.JSON {
		return writeJSON(w, j)
	}
	switch {
	case j.Auto:
		fmt.Fprintf(w, "Automation #%d: %s is auto.\n", j.AutomationID, j.Tool)
	case j.Changed:
		fmt.Fprintf(w, "Automation #%d: %s asks again.\n", j.AutomationID, j.Tool)
	default:
		fmt.Fprintf(w, "Automation #%d: %s had no auto grant.\n", j.AutomationID, j.Tool)
	}
	return nil
}
