package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"watchtower/internal/tools"
)

var (
	jiraCreateFlagProject     string
	jiraCreateFlagType        string
	jiraCreateFlagSummary     string
	jiraCreateFlagDescription string
	jiraCreateFlagLabels      []string
	jiraCreateFlagPriority    string
	jiraCreateFlagJSON        bool
)

var jiraCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create a Jira issue (the CLI face of the create_jira_issue tool)",
	Long: `Create an issue on the connected Jira site and store it locally so it is
immediately visible to the read tools. Runs the same validation and execution
the assistant's create_jira_issue proposal runs on Approve — without a proposal.`,
	RunE: runJiraCreate,
}

func init() {
	jiraCmd.AddCommand(jiraCreateCmd)
	jiraCreateCmd.Flags().StringVar(&jiraCreateFlagProject, "project", "", "project key (required)")
	jiraCreateCmd.Flags().StringVar(&jiraCreateFlagType, "type", "", "issue type name, e.g. Task (required)")
	jiraCreateCmd.Flags().StringVar(&jiraCreateFlagSummary, "summary", "", "issue summary (required)")
	jiraCreateCmd.Flags().StringVar(&jiraCreateFlagDescription, "description-file", "", "plain-text description file")
	jiraCreateCmd.Flags().StringArrayVar(&jiraCreateFlagLabels, "label", nil, "label (repeatable)")
	jiraCreateCmd.Flags().StringVar(&jiraCreateFlagPriority, "priority", "", "priority name")
	jiraCreateCmd.Flags().BoolVar(&jiraCreateFlagJSON, "json", false, "output JSON")
	_ = jiraCreateCmd.MarkFlagRequired("project")
	_ = jiraCreateCmd.MarkFlagRequired("type")
	_ = jiraCreateCmd.MarkFlagRequired("summary")
}

func runJiraCreate(cmd *cobra.Command, _ []string) error {
	description := ""
	if jiraCreateFlagDescription != "" {
		b, err := os.ReadFile(jiraCreateFlagDescription)
		if err != nil {
			return fmt.Errorf("reading --description-file: %w", err)
		}
		description = string(b)
	}
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()

	args, err := json.Marshal(map[string]any{
		"account_id": jiraFlagAccount, "project_key": jiraCreateFlagProject, "issue_type": jiraCreateFlagType,
		"summary": jiraCreateFlagSummary, "description": description, "labels": jiraCreateFlagLabels,
		"priority": jiraCreateFlagPriority, "reason": "created from the CLI",
	})
	if err != nil {
		return err
	}
	tool := tools.NewCreateJiraIssue(jiraClientFactory(cfg))
	out, err := tools.RunDirect(context.Background(), database, tool, args)
	if err != nil {
		if jiraCreateFlagJSON {
			_ = writeJSON(cmd.OutOrStdout(), map[string]any{"ok": false, "error": err.Error()})
		}
		return err
	}
	res := out.(map[string]any)
	if jiraCreateFlagJSON {
		return writeJSON(cmd.OutOrStdout(), map[string]any{"ok": true, "key": res["key"], "url": res["url"]})
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Created %s — %s\n", res["key"], res["url"])
	return nil
}
