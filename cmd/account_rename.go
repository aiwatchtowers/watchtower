package cmd

import (
	"fmt"
	"strconv"

	"github.com/spf13/cobra"
)

// `<source> rename <account-id> <name>` — renames a connected account. The
// name an account gets at connect is automatic (db.SlackAccountLabel and its
// siblings); this is how the owner changes it, and what the Desktop's
// Settings → Rename… runs.

// newAccountRenameCmd builds the rename subcommand for the accounts in table;
// noun names one account in help text ("Slack workspace", "mailbox").
func newAccountRenameCmd(table, noun string) *cobra.Command {
	return &cobra.Command{
		Use:   "rename <account-id> <name>",
		Short: "Rename a connected " + noun,
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, err := strconv.ParseInt(args[0], 10, 64)
			if err != nil {
				return fmt.Errorf("invalid account id %q: %w", args[0], err)
			}
			_, database, err := openSlackCmdDB()
			if err != nil {
				return err
			}
			defer database.Close()
			if err := database.RenameAccount(table, id, args[1]); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Renamed account %d.\n", id)
			return nil
		},
	}
}

func init() {
	slackCmd.AddCommand(newAccountRenameCmd("slack_accounts", "Slack workspace"))
	jiraCmd.AddCommand(newAccountRenameCmd("jira_accounts", "Jira site"))
	googleCmd.AddCommand(newAccountRenameCmd("google_accounts", "Google account"))
	// email_accounts holds both IMAP and Outlook mailboxes.
	imapCmd.AddCommand(newAccountRenameCmd("email_accounts", "mailbox (IMAP or Outlook)"))
	outlookCmd.AddCommand(newAccountRenameCmd("email_accounts", "mailbox (IMAP or Outlook)"))
	caldavCmd.AddCommand(newAccountRenameCmd("calendar_accounts", "calendar (CalDAV or ICS)"))
}
