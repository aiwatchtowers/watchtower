package diagnostics

// SourceTable is one source kind of the Sources line (spec "Sources"
// mapping): the account table it is counted from, its aggregate read, how
// each status value is counted, and its checkbox label on the bug form.
type SourceTable struct {
	// Kind is the printed name (Kind* in text.go).
	Kind string
	// Table is the account table read, for TestDiagnostics_AccountTablesMapped.
	Table string
	// Query returns rows of (status TEXT, enabled INTEGER, count INTEGER),
	// filtered to this kind and grouped by status and enabled. A table
	// without an enabled column selects 1.
	Query string
	// Statuses maps a stored status to its printed state (Status* in
	// text.go); "" means the row is not counted (`removed`). A value not in
	// the map prints as `<k> unknown state`.
	Statuses map[string]string
	// Unit follows the count (`Confluence 3 spaces …`); "" for accounts.
	Unit string
	// FormLabel is the bug form's checkbox for JSON `sources`; "" when the
	// form has none.
	FormLabel string
}

// slackLikeStatuses covers slack/jira/linear_accounts: ok | error | revoked
// | removed | purged.
var slackLikeStatuses = map[string]string{
	"ok":      StatusOK,
	"error":   StatusError,
	"revoked": StatusNeedsSignIn,
	"purged":  StatusPurged,
	"removed": "",
}

// googleStatuses covers google_accounts: ok | error | revoked | purged.
var googleStatuses = map[string]string{
	"ok":      StatusOK,
	"error":   StatusError,
	"revoked": StatusNeedsSignIn,
	"purged":  StatusPurged,
}

// confluenceStatuses covers ext_sources' CHECK: ok | error | needs_consent
// | revoked.
var confluenceStatuses = map[string]string{
	"ok":            StatusOK,
	"error":         StatusError,
	"needs_consent": StatusNeedsSignIn,
	"revoked":       StatusNeedsSignIn,
}

// mailStatuses covers email_accounts and calendar_accounts: ok | error |
// revoked.
var mailStatuses = map[string]string{
	"ok":      StatusOK,
	"error":   StatusError,
	"revoked": StatusNeedsSignIn,
}

// SourceTables is the spec's Sources mapping in printed order. Every
// `%_accounts` table of a migrated database must appear here
// (TestDiagnostics_AccountTablesMapped). Quick Connections are counted
// separately (quickConnectionsQuery).
var SourceTables = []SourceTable{
	{
		Kind: KindSlack, Table: "slack_accounts", FormLabel: KindSlack, Statuses: slackLikeStatuses,
		Query: `SELECT status, enabled, count(*) FROM slack_accounts GROUP BY status, enabled`,
	},
	{
		Kind: KindGmail, Table: "google_accounts", FormLabel: KindGmail, Statuses: googleStatuses,
		Query: `SELECT status, 1, count(*) FROM google_accounts WHERE gmail_enabled = 1 GROUP BY status`,
	},
	{
		Kind: KindGoogleCalendar, Table: "google_accounts", FormLabel: KindGoogleCalendar, Statuses: googleStatuses,
		Query: `SELECT status, 1, count(*) FROM google_accounts WHERE calendar_enabled = 1 GROUP BY status`,
	},
	{
		Kind: KindJira, Table: "jira_accounts", FormLabel: KindJira, Statuses: slackLikeStatuses,
		Query: `SELECT status, enabled, count(*) FROM jira_accounts GROUP BY status, enabled`,
	},
	{
		Kind: KindConfluence, Table: "ext_sources", FormLabel: KindConfluence, Statuses: confluenceStatuses,
		Unit:  ConfluenceSpaces,
		Query: `SELECT status, enabled, count(*) FROM ext_sources WHERE provider = 'confluence' GROUP BY status, enabled`,
	},
	{
		Kind: KindLinear, Table: "linear_accounts", FormLabel: KindLinear, Statuses: slackLikeStatuses,
		Query: `SELECT status, enabled, count(*) FROM linear_accounts GROUP BY status, enabled`,
	},
	{
		Kind: KindEmailIMAP, Table: "email_accounts", FormLabel: FormEmailOverIMAP, Statuses: mailStatuses,
		Query: `SELECT status, 1, count(*) FROM email_accounts WHERE provider = 'imap' GROUP BY status`,
	},
	{
		Kind: KindOutlook, Table: "email_accounts", FormLabel: FormEmailOverIMAP, Statuses: mailStatuses,
		Query: `SELECT status, 1, count(*) FROM email_accounts WHERE provider = 'outlook' GROUP BY status`,
	},
	{
		Kind: KindCalDAV, Table: "calendar_accounts", Statuses: mailStatuses,
		Query: `SELECT status, 1, count(*) FROM calendar_accounts GROUP BY status`,
	},
}

// stateOrder is the order states print in inside `( … )`.
var stateOrder = []string{StatusNeedsSignIn, StatusError, StatusPurged, StatusOff, StatusUnknownState}

// kindTally counts one kind's rows by printed state.
type kindTally struct {
	total  int
	states map[string]int
}

// add counts n rows of one (status, enabled) group: a status mapped to ""
// is not counted, a disabled row is `off`, an unmapped status is
// `unknown state`.
func (k *kindTally) add(st SourceTable, status string, enabled bool, n int) {
	state, known := st.Statuses[status]
	switch {
	case known && state == "":
		return
	case !enabled:
		state = StatusOff
	case !known:
		state = StatusUnknownState
	}
	if k.states == nil {
		k.states = map[string]int{}
	}
	k.total += n
	k.states[state] += n
}

// text is `<kind> <n>[ <unit>] ok` or `<kind> <n>[ <unit>] (<k> <state>, …)`;
// "" when nothing is counted.
func (k kindTally) text(st SourceTable) string {
	if k.total == 0 {
		return ""
	}
	head := kindCount(st.Kind, k.total)
	if st.Unit != "" {
		head = kindWord(head, st.Unit)
	}
	if k.states[StatusOK] == k.total {
		return kindWord(head, StatusOK)
	}
	var states []string
	for _, s := range stateOrder {
		if n := k.states[s]; n > 0 {
			states = append(states, stateCount(n, s))
		}
	}
	return kindStates(head, states)
}
