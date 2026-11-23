package policy

// ITGuideURL is the public page that documents every key for IT (D21): the
// app links to it and `policy show` names it. The website renders its key
// table from docs/mdm/keys.json; TestITGuideURL_NotPlaceholder keeps the
// placeholder below from coming back.
const ITGuideURL = "https://aiwatchtowers.com/guide/mdm/"

// itGuidePlaceholder is the address used before the page existed.
const itGuidePlaceholder = "https://example.com/mdm"

// KeyDoc is one key as `policy keys --json` prints it and docs/mdm/keys.json
// holds it; the public IT page renders its table from that file.
type KeyDoc struct {
	Key     string `json:"key"`
	Type    string `json:"type"`
	Default string `json:"default"`
	Effect  string `json:"effect"`
}

// keyDocs is every key's line, by key.
var keyDocs = map[string]KeyDoc{
	KeyAllowedSources: {Type: "array of strings", Default: "not set: every source",
		Effect: "Which connectors may run: slack, google (Gmail and Google Calendar), imap (Outlook included), caldav, jira (Confluence included), linear. A source left out stops syncing and keeps its data."},
	KeyMobileSync: {Type: "string", Default: "allowed",
		Effect: "Whether the iPhone companion may sync: allowed, workbench_only (workbench data only) or off."},
	KeyAllowedQuickConnections: {Type: "array of strings", Default: "not set: every Quick Connection",
		Effect: "Which Quick Connections (MCP servers) may be added and used: https:// URL prefixes and absolute command paths."},
	KeyAllowAutomationShell: {Type: "boolean", Default: "true",
		Effect: "Whether automations may run shell commands."},
	KeyAllowedAIProviders: {Type: "array of strings", Default: "not set: every provider",
		Effect: "Which AI providers may be used: claude, codex, ollama. A forbidden provider is never a fallback."},
	KeyAllowClaudeAITools: {Type: "boolean", Default: "true",
		Effect: "Whether the chat may offer claude.ai publishing and connectors."},
	KeyPurgeRevokedData: {Type: "boolean", Default: "not set: the person's own setting",
		Effect: "Whether an account whose access was revoked has its data wiped."},
	KeyPurgeGraceHours: {Type: "integer", Default: "not set: 72 hours",
		Effect: "Hours of notice before the data of an account whose access ended is deleted, 0 to 720. 0 deletes it on the next sync cycle. A value outside the range or not a whole number is ignored."},
	KeyAllowBackgroundAI: {Type: "boolean", Default: "not set: each person is asked",
		Effect: "true is the organization's consent to AI that runs in the background, so people are not asked; each person can still pause it. false keeps background AI off and locks the switch."},
	KeySlackApps: {Type: "array of dictionaries", Default: "not set: none",
		Effect: "The company's own Slack apps, one entry per workspace with team_id (T…) and client_id. Connections → Slack offers a one-press Connect for each; it never connects anyone. A malformed or duplicate entry is dropped."},
	KeyCompanyBundle: {Type: "string", Default: "not set: no company",
		Effect: "The company bundle (the same code a company link carries): the company's app for every connector and its link deny list. Shows Connect all without a link; wins over a stored bundle of the same company and never deletes accounts."},
	KeyAllowAtlassianAPIToken: {Type: "boolean", Default: "true",
		Effect: "Whether Jira may be connected with an Atlassian API token. false hides the option; token accounts stop syncing and keep their data."},
	KeyAllowOwnGoogleProject: {Type: "boolean", Default: "true",
		Effect: "Whether a person may connect Google through their own Google Cloud project. false hides and refuses the option; accounts on an own project (also one added earlier with a custom OAuth client) stop syncing and keep their data, company and shared-client accounts are untouched."},
	KeyRequireDatabaseEncryption: {Type: "boolean", Default: "not set",
		Effect: "Reserved: read and shown, not enforced in this version."},
	KeyRetentionDays: {Type: "integer", Default: "not set",
		Effect: "Reserved: read and shown, not enforced in this version."},
	KeyBulkReadLimits: {Type: "dictionary", Default: "not set",
		Effect: "Reserved: read and shown, not enforced in this version."},
}

// KeyDocs returns every key in Keys, then ReservedKeys, in display order.
func KeyDocs() []KeyDoc {
	out := make([]KeyDoc, 0, len(Keys)+len(ReservedKeys))
	for _, keys := range [][]string{Keys, ReservedKeys} {
		for _, k := range keys {
			d := keyDocs[k]
			d.Key = k
			out = append(out, d)
		}
	}
	return out
}
