package automations

import (
	"strings"
	"unicode"

	"watchtower/internal/db"
)

// MaxFolderSlugBytes caps output.inbox's folder: a real slug comes from a
// title of at most 60 characters, so anything longer names no folder.
const MaxFolderSlugBytes = 80

// inboxFolderField is output.inbox's folder field (Inbox builder B): the slug
// of the Inbox folder the card goes to. It checks the value's shape only and
// buffers the slug; the run's commit resolves it inside its transaction, so a
// folder deleted after the call never fails the commit, and a slug no folder
// takes puts the card on its automation's route with a journal line
// (db.AutomationOutput.FolderSlug). A script never creates a folder.
func inboxFolderField(_ *Env, fn string, v any, o *db.AutomationOutput) error {
	slug, ok := v.(string)
	if !ok || slug == "" || len(slug) > MaxFolderSlugBytes || strings.ContainsFunc(slug, unicode.IsControl) {
		return validationf("%s(): folder must be a folder name", fn)
	}
	o.FolderSlug = slug
	return nil
}
