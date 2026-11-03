package cmd

import (
	"errors"
	"fmt"
	"io"
	"strings"

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
// the database handle is query_only). Owner-only (AUTO-06): refused under
// every agent marker before stdin is read; unlike the chat tool it dry-runs
// an indexed recipe that is not confirmed yet, as the card's Dry run does.
// Its llm() tokens are the owner's spend on the owner's press.
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
	if strings.TrimSpace(string(raw)) == "" {
		return errors.New(previewUsage)
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
	res, err := authoring.EvaluateDraft(cmd.Context(), deps, string(raw), authoring.DraftTarget{
		Slug: autoFlags.Slug, WorkbenchID: autoFlags.Workbench, BuiltinID: autoFlags.Builtin,
	})
	if err != nil {
		return err
	}
	return writeJSON(cmd.OutOrStdout(), res)
}
