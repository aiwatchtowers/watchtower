package automations

import "watchtower/internal/db"

// inboxFolderField is output.inbox's folder field (Inbox builder B): the slug
// of the Inbox folder the card goes to. It checks the value's shape only and
// buffers the slug; the run's commit resolves it inside its transaction, so a
// folder deleted after the call never fails the commit, and a slug no folder
// takes puts the card on its automation's route with a journal line
// (db.AutomationOutput.FolderSlug). A script never creates a folder.
func inboxFolderField(_ *Env, fn string, v any, o *db.AutomationOutput) error {
	slug, ok := v.(string)
	if !ok || slug == "" {
		return validationf("%s(): folder must be a folder name", fn)
	}
	o.FolderSlug = slug
	return nil
}
