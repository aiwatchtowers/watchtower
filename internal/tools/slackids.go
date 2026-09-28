package tools

import (
	"fmt"

	"watchtower/internal/db"
	"watchtower/internal/slack"
)

// slackIDForms returns every stored form a Slack id reference may take in the
// DB, for an exact-match lookup (index-friendly `id IN (...)`, no LIKE).
//
// Since migration 00048 every stored Slack id is namespaced "<account>:<raw>",
// but an LLM caller holds either form: a raw id (U…/W…/C…/G…/D…) copied out of
// Slack text or a permalink, or a namespaced one returned by another tool. A
// namespaced ref is returned as-is — it already pins one account. A raw ref
// expands to its namespaced form under EVERY Slack account (removed and
// disabled ones included: their synced data stays queryable), in account-id
// order, followed by the raw ref itself for any pre-00048 row left bare. So a
// raw id that exists in two connected workspaces deliberately matches both;
// the namespaced form is how a caller picks one.
func slackIDForms(d *db.DB, ref string) ([]string, error) {
	if _, _, ok := slack.SplitAccountID(ref); ok {
		return []string{ref}, nil
	}
	accounts, err := d.ListSlackAccounts()
	if err != nil {
		return nil, fmt.Errorf("resolving slack id: %w", err)
	}
	forms := make([]string, 0, len(accounts)+1)
	for _, a := range accounts {
		forms = append(forms, slack.Namespace(a.ID, ref))
	}
	return append(forms, ref), nil
}

// rawSlackID strips an account namespace, if any, for shape checks.
func rawSlackID(ref string) string {
	_, raw, _ := slack.SplitAccountID(ref)
	return raw
}

// looksLikeUserID reports whether s is shaped like a Slack user id, raw or
// namespaced: a leading U or W followed by all-uppercase alphanumerics (e.g.
// U0FAKE08 or 1:U0FAKE08). The strict shape keeps ordinary names that merely
// start with U/W (e.g. "Ulyana") on the name-resolution path instead of being
// mistaken for an id.
func looksLikeUserID(s string) bool {
	raw := rawSlackID(s)
	return len(raw) >= 8 && (raw[0] == 'U' || raw[0] == 'W') && upperAlnum(raw[1:])
}

// looksLikeChannelID reports whether s is shaped like a Slack channel id, raw
// or namespaced: C (public), G (private/group) or D (DM) followed by
// uppercase alphanumerics. Slack channel names are always lowercase, so the
// uppercase test keeps a name from being taken for an id.
func looksLikeChannelID(s string) bool {
	raw := rawSlackID(s)
	return len(raw) >= 2 && (raw[0] == 'C' || raw[0] == 'G' || raw[0] == 'D') && upperAlnum(raw[1:])
}

func upperAlnum(s string) bool {
	for _, r := range s {
		if !(r >= 'A' && r <= 'Z') && !(r >= '0' && r <= '9') {
			return false
		}
	}
	return true
}
