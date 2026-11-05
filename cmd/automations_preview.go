package cmd

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/spf13/cobra"

	"watchtower/internal/automations"
	"watchtower/internal/automations/authoring"
)

// previewVerb is the AGENT-07 gesture `automations preview` makes.
const previewVerb = "dry-run a recipe preview"

// previewOwnerHint ends the refusal of a preview under an agent marker.
const previewOwnerHint = "only the owner can preview a recipe; use Dry run in the automation editor's Look step"

// previewUsage is the refusal of a preview without --stdin and --json, or
// with nothing on stdin.
const previewUsage = "usage: watchtower automations preview --stdin --json [--slug S] [--workbench N] [--builtin ID] < recipe.md"

// runAutomationsPreview is the owner's Dry run in the editor's Look step
// (Inbox builder A, ask #445): the recipe text on stdin is evaluated as
// draft_automation evaluates it — validated, then dry-run in memory with the
// draft bounds — and its DraftResult (draft_automation's pinned keys) is
// printed. It writes no row of any table and no draft-cache entry (AUTO-12:
// the database handle is query_only). Owner-only (AUTO-06, AGENT-07): refused
// under every agent marker before stdin is read, and then run only after the
// owner confirms it in the running Desktop (confirmWithOwner, the window
// showing the text; the Desktop's own launch is granted without a window) —
// before the database is opened or anything evaluated. Unlike the chat tool
// it dry-runs an indexed recipe that is not confirmed yet, as the card's Dry
// run does. Its llm() tokens are the owner's spend on the owner's press.
func runAutomationsPreview(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent(previewVerb); err != nil {
		return fmt.Errorf("%w; %s", err, previewOwnerHint)
	}
	if !autoFlags.Stdin || !autoFlags.JSON {
		return errors.New(previewUsage)
	}
	raw, err := io.ReadAll(io.LimitReader(cmd.InOrStdin(), automations.MaxRecipeBytes+1))
	if err != nil {
		return fmt.Errorf("reading the recipe from stdin: %w", err)
	}
	text := string(raw)
	if strings.TrimSpace(text) == "" {
		return errors.New(previewUsage)
	}
	target := authoring.DraftTarget{Slug: autoFlags.Slug, WorkbenchID: autoFlags.Workbench, BuiltinID: autoFlags.Builtin}
	if err := confirmWithOwner(previewVerb, previewConfirmDetail(target, text)); err != nil {
		return fmt.Errorf("%w; %s", err, previewOwnerHint)
	}
	cfg, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	if err := database.SetReadOnly(); err != nil {
		return err
	}
	deps := automationAuthoringDeps(cfg, database, nil)
	deps.Backends = func() automations.Backends {
		return automationBackends(cfg, database, automationsDryRunGenerator(cfg))
	}
	// The Desktop's Stop terminates this process: the cancelled context
	// ends the in-flight model child too, instead of leaving it to spend
	// tokens (as `dry-run` does).
	ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	res, err := authoring.EvaluateDraft(ctx, deps, text, target)
	if err != nil {
		return err
	}
	return writeJSON(cmd.OutOrStdout(), res)
}

// previewConfirmDetail is the owner's confirmation window for a preview:
// what the text edits and the whole text the dry run would execute.
func previewConfirmDetail(t authoring.DraftTarget, text string) string {
	edits := "a new recipe"
	switch {
	case t.BuiltinID != "":
		edits = fmt.Sprintf("built-in %q", t.BuiltinID)
	case t.Slug != "" && t.WorkbenchID > 0:
		edits = fmt.Sprintf("%q in workbench #%d", t.Slug, t.WorkbenchID)
	case t.Slug != "":
		edits = fmt.Sprintf("%q", t.Slug)
	case t.WorkbenchID > 0:
		edits = fmt.Sprintf("a new recipe in workbench #%d", t.WorkbenchID)
	}
	return fmt.Sprintf("Dry run in memory of %s: its reads and llm() calls run for real, nothing is written.\n\n%s",
		edits, text)
}
