package cmd

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/ownerconfirm"
	"watchtower/internal/reviewdiff"
)

// askOwnerDesktop is the Desktop round trip; tests replace it.
var askOwnerDesktop = ownerconfirm.Ask

// confirmWithOwner is AGENT-07's second step (board #568, owner decision
// ask #357, variant A): after refuseUnderAgent let a process without an
// agent marker through, an owner-only gesture still runs only when the owner
// confirms it in the running Watchtower Desktop. The CLI sends the request
// over the workspace's socket, checks that the process answering is the
// Watchtower app signed by this CLI's own team (ownerconfirm.Ask), and waits
// for the owner's click. No Desktop, a peer that fails the check, or any
// other error is a refusal — there is no fallback. The Desktop answers the
// commands it started itself without a window. detail is shown in the window
// in full (the args, the recipe, the lesson, the hunk).
//
// It protects against an agent talked into running the command (a prompt
// injection), not against a malicious program running as the owner, which
// can write the database itself.
func confirmWithOwner(verb, detail string) error {
	ctx, cancel := context.WithTimeout(context.Background(), ownerconfirm.Wait)
	defer cancel()
	rep, err := askOwnerDesktop(ctx, ownerConfirmSocket(), ownerconfirm.Request{
		Verb: verb, Detail: detail, Args: os.Args[1:],
	})
	switch {
	case errors.Is(err, ownerconfirm.ErrNoDesktop):
		return fmt.Errorf("refusing to %s: open Watchtower to confirm this — the owner confirms it in Watchtower Desktop, "+
			"which is not running for this workspace", verb)
	case err != nil:
		return fmt.Errorf("refusing to %s: %w", verb, err)
	case rep.Decision != ownerconfirm.Confirmed:
		why := "the owner did not confirm it in Watchtower Desktop"
		if rep.Reason != "" {
			why = rep.Reason
		}
		return fmt.Errorf("refusing to %s: %s", verb, why)
	}
	return nil
}

// requireOwner is refuseUnderAgent then confirmWithOwner, for a gesture whose
// window needs no detail read from the database.
func requireOwner(verb string) error {
	if err := refuseUnderAgent(verb); err != nil {
		return err
	}
	return confirmWithOwner(verb, "")
}

// ownerConfirmSocket is the Desktop's socket for the workspace this command
// works on; "" (no Desktop) when the config cannot be read.
func ownerConfirmSocket() string {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return ""
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if cfg.ValidateWorkspace() != nil {
		return ""
	}
	return ownerconfirm.SocketPath(cfg.DBPath())
}

// actionConfirmDetail is what the window shows for the action idArg names:
// its tool, its stored args and the --patch edits, unclipped; "" when the row
// cannot be read (the command reports that itself).
func actionConfirmDetail(idArg string) string {
	id, err := parseActionID(idArg)
	if err != nil {
		return ""
	}
	database, err := openDBFromConfig()
	if err != nil {
		return ""
	}
	defer database.Close()
	row, err := database.GetAgentAction(id)
	if err != nil || row == nil {
		return ""
	}
	detail := fmt.Sprintf("Action #%d — %s\nArgs: %s", id, row.Tool, row.ArgsJSON)
	if actionsFlagPatch != "" {
		detail += "\nWith your edits: " + actionsFlagPatch
	}
	return detail
}

// recipeConfirmDetail is the window's text for an automation: where its
// recipe lives and the whole recipe — frontmatter (trigger, budgets,
// permissions, outputs) and script.
func recipeConfirmDetail(a *db.Automation) string {
	if a == nil {
		return ""
	}
	return fmt.Sprintf("Automation #%d %q (%s)\nTrigger: %s %s\nPermissions: %s\nOutputs: %s\n\n%s",
		a.ID, a.Name, a.Path, a.TriggerKind, a.TriggerSpec, a.PermissionsJSON, a.OutputsJSON, a.RecipeText)
}

// automationConfirmDetail reads the automation arg names for the window; ""
// when it cannot be read (the command reports that itself).
func automationConfirmDetail(arg string) string {
	id, err := parseAutomationID("automation id", arg)
	if err != nil {
		return ""
	}
	database, err := openDBFromConfig()
	if err != nil {
		return ""
	}
	defer database.Close()
	a, err := database.GetAutomation(id)
	if err != nil {
		return ""
	}
	return recipeConfirmDetail(a)
}

// lessonConfirmDetail is the window's text for the --lesson of a workbench.
func lessonConfirmDetail(database *db.DB, workbenchID int64) string {
	l, err := database.GetReviewLesson(workbenchID, reviewFlagLesson)
	if err != nil || l == nil {
		return ""
	}
	return "Lesson (" + l.Lens + "):\n\n" + l.Text
}

// hunkConfirmDetail is the window's text for an Undo: the file and the hunk.
func hunkConfirmDetail(d reviewdiff.Diff, hunkID string) string {
	for _, f := range d.Files {
		for _, h := range f.Hunks {
			if h.ID == hunkID {
				return f.Path + "\n" + h.Header + "\n" + strings.Join(h.Lines, "\n")
			}
		}
	}
	return ""
}
