package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// JiraWriteClient is the slice of *jira.Client the four issue-write tools
// need — the JiraIssueClient seam's sibling, so tests inject a fake.
type JiraWriteClient interface {
	GetIssue(ctx context.Context, key string) (jira.Issue, error)
	AddComment(ctx context.Context, key, body string) (string, error)
	GetTransitions(ctx context.Context, key string) ([]jira.Transition, error)
	TransitionIssue(ctx context.Context, key, transitionID string) error
	AssignIssue(ctx context.Context, key, accountID string) error
	UpdateIssue(ctx context.Context, key string, f jira.IssueUpdate) error
	SearchUsers(ctx context.Context, query string) ([]jira.User, error)
}

// JiraWriteClientFactory builds a write client for one connected account.
type JiraWriteClientFactory func(account db.JiraAccount) (JiraWriteClient, error)

// JiraWriteTools returns the four existing-issue write tools, in their
// registration order. All are External (AGENT-03): each leaves the machine.
func JiraWriteTools(f JiraWriteClientFactory) []*Tool {
	return []*Tool{NewAddJiraComment(f), NewTransitionJiraIssue(f), NewAssignJiraIssue(f), NewUpdateJiraIssue(f)}
}

var issueKeyRE = regexp.MustCompile(`^[A-Z][A-Z0-9_]+-\d+$`)

// resolveIssueTarget normalizes the key and picks the site it lives on:
// explicit account_id → the one site whose mirror holds the key → the single
// enabled account. A key mirrored on several sites needs account_id.
func resolveIssueTarget(d *db.DB, accountID int64, rawKey string) (db.JiraAccount, string, error) {
	key := strings.ToUpper(strings.TrimSpace(rawKey))
	if !issueKeyRE.MatchString(key) {
		return db.JiraAccount{}, "", &ValidationError{Msg: fmt.Sprintf("key %q is not a Jira issue key (e.g. ABC-123)", rawKey)}
	}
	if accountID > 0 {
		a, err := ResolveJiraAccount(d, accountID)
		return a, key, err
	}
	ids, err := d.JiraAccountIDsForIssueKey(key)
	if err != nil {
		return db.JiraAccount{}, "", err
	}
	switch len(ids) {
	case 0:
		a, err := ResolveJiraAccount(d, 0)
		return a, key, err
	case 1:
		a, err := ResolveJiraAccount(d, ids[0])
		return a, key, err
	default:
		return db.JiraAccount{}, "", &ValidationError{Msg: fmt.Sprintf("%s exists on several connected Jira sites — pass account_id (see list_jira_projects)", key)}
	}
}

// openIssue resolves the target and builds its client.
func openIssue(d *db.DB, factory JiraWriteClientFactory, accountID int64, rawKey string) (db.JiraAccount, JiraWriteClient, string, error) {
	account, key, err := resolveIssueTarget(d, accountID, rawKey)
	if err != nil {
		return db.JiraAccount{}, nil, "", err
	}
	client, err := factory(account)
	if err != nil {
		return db.JiraAccount{}, nil, "", err
	}
	return account, client, key, nil
}

// mergeJSON decodes raw as a JSON object, overlays patch on top of it, and
// re-encodes. It is how a tool's Normalize pins a resolved value into the
// args Propose persists, without disturbing the fields it doesn't touch
// (reason, the original free-text fields the owner sees echoed back, etc).
func mergeJSON(raw json.RawMessage, patch map[string]any) (json.RawMessage, error) {
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("normalize: decoding args: %w", err)
	}
	for k, v := range patch {
		m[k] = v
	}
	out, err := json.Marshal(m)
	if err != nil {
		return nil, fmt.Errorf("normalize: encoding args: %w", err)
	}
	return out, nil
}

// pinSite resolves the site key targets right now and bakes that choice into
// the persisted args (account_id, and the normalized key). Without this, a
// call proposed while the key lived on exactly one site — or on none, falling
// back to the single enabled account — could apply against a DIFFERENT site
// hours later if a second site's mirror picked up the same key or a new
// account was connected in between; resolveIssueTarget's explicit-account_id
// branch (called from Execute at apply time) then never re-picks.
func pinSite(d *db.DB, raw json.RawMessage, accountID int64, key string) (json.RawMessage, error) {
	account, resolvedKey, err := resolveIssueTarget(d, accountID, key)
	if err != nil {
		return nil, err
	}
	return mergeJSON(raw, map[string]any{"account_id": account.ID, "key": resolvedKey})
}

// jiraWriteFailed marks the account revoked on ErrAuthRevoked (Execute only —
// Validate never writes) and folds a failed marking into the error, the
// create_jira_issue shape.
func jiraWriteFailed(d *db.DB, accountID int64, err error) error {
	if dbErr := recordRevokedGrant(d, accountID, err); dbErr != nil {
		return fmt.Errorf("%w (and recording the revoked state failed: %v)", err, dbErr)
	}
	return err
}

func browseURL(account db.JiraAccount, key string) string {
	return strings.TrimRight(account.SiteURL, "/") + "/browse/" + key
}

// issueResult is the one result shape every issue-write tool returns; the
// Desktop card renders url+label generically.
func issueResult(ctx context.Context, d *db.DB, client JiraWriteClient, accountID int64, key, url, label string) map[string]any {
	result := map[string]any{"key": key, "url": url, "label": label}
	if warning := refreshIssueMirror(ctx, d, client, accountID, key); warning != "" {
		result["warning"] = warning
	}
	return result
}

// refreshIssueMirror re-reads the issue after a write and stores it. The
// write already happened in Jira, so nothing here fails the action; the
// owner is told the mirror is stale and the next sync repairs it.
func refreshIssueMirror(ctx context.Context, d *db.DB, client JiraWriteClient, accountID int64, key string) string {
	const prefix = "applied, but the local mirror was not updated: "
	issue, err := client.GetIssue(ctx, key)
	if err != nil {
		return prefix + err.Error()
	}
	row, err := refreshedIssueRow(d, accountID, issue)
	if err != nil {
		return prefix + err.Error()
	}
	if err := d.UpsertJiraIssue(row); err != nil {
		return prefix + err.Error()
	}
	return ""
}

// refreshedIssueRow overlays what these writes can change onto the stored
// row, so board/sprint/epic/reporter/custom-field columns the syncer owns
// survive (issueRow alone would blank them). A key not mirrored yet gets
// issueRow's shape.
func refreshedIssueRow(d *db.DB, accountID int64, issue jira.Issue) (db.JiraIssue, error) {
	fresh := issueRow(accountID, issue)
	existing, err := d.GetJiraIssue(accountID, issue.Key)
	if err != nil {
		return db.JiraIssue{}, err
	}
	row := fresh
	if existing != nil {
		row = *existing
		row.Summary, row.DescriptionText = fresh.Summary, fresh.DescriptionText
		row.Status, row.StatusCategory, row.StatusCategoryChangedAt = fresh.Status, fresh.StatusCategory, fresh.StatusCategoryChangedAt
		row.Priority, row.Labels = fresh.Priority, fresh.Labels
		row.ResolvedAt = fresh.ResolvedAt
		row.UpdatedAt, row.RawJSON, row.SyncedAt = fresh.UpdatedAt, fresh.RawJSON, fresh.SyncedAt
	}
	f := issue.Fields
	row.DueDate = ""
	if f.DueDate != nil {
		row.DueDate = *f.DueDate
	}
	row.AssigneeAccountID, row.AssigneeEmail, row.AssigneeDisplayName, row.AssigneeSlackID = "", "", "", ""
	if f.Assignee != nil {
		row.AssigneeAccountID = f.Assignee.AccountID
		row.AssigneeEmail = f.Assignee.EmailAddress
		row.AssigneeDisplayName = f.Assignee.DisplayName
		m, err := d.GetJiraUserMapByAccountID(f.Assignee.AccountID)
		if err != nil {
			return db.JiraIssue{}, err
		}
		if m != nil {
			row.AssigneeSlackID = m.SlackUserID
		}
	}
	return row, nil
}

func mustWriteSchema[T any](name string) *jsonschema.Schema {
	schema, err := jsonschema.For[T](nil)
	if err != nil {
		panic(name + " schema: " + err.Error())
	}
	return schema
}

// ---- add_jira_comment -------------------------------------------------------

type addJiraCommentArgs struct {
	AccountID int64  `json:"account_id,omitempty" jsonschema:"connected Jira account id; needed only when the key exists on several sites (see list_jira_projects)"`
	Key       string `json:"key" jsonschema:"issue key, e.g. ABC-123"`
	Body      string `json:"body" jsonschema:"plain-text comment; blank lines separate paragraphs"`
	Reason    string `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
}

// NewAddJiraComment builds the add_jira_comment write tool.
func NewAddJiraComment(factory JiraWriteClientFactory) *Tool {
	return &Tool{
		Name: "add_jira_comment",
		Description: "Propose a comment on an existing Jira issue. The owner approves it in the chat before " +
			"anything is sent to Jira.",
		InputSchema: mustWriteSchema[addJiraCommentArgs]("add_jira_comment"),
		Access:      AccessWrite,
		External:    true,
		Surfaces:    []string{"main", "target"},
		Validate: func(_ context.Context, d *db.DB, raw json.RawMessage) error {
			var a addJiraCommentArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			switch body := strings.TrimSpace(a.Body); {
			case body == "":
				return &ValidationError{Msg: "body is required"}
			case len([]rune(body)) > 32000:
				return &ValidationError{Msg: "body must be at most 32000 characters"}
			}
			_, _, err := resolveIssueTarget(d, a.AccountID, a.Key)
			return err
		},
		Normalize: func(_ context.Context, d *db.DB, raw json.RawMessage) (json.RawMessage, error) {
			var a addJiraCommentArgs
			if err := decodeStrict(raw, &a); err != nil {
				return nil, err
			}
			return pinSite(d, raw, a.AccountID, a.Key)
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a addJiraCommentArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding add_jira_comment args: %w", err)
			}
			account, client, key, err := openIssue(d, factory, a.AccountID, a.Key)
			if err != nil {
				return nil, err
			}
			id, err := client.AddComment(ctx, key, a.Body)
			if err != nil {
				return nil, jiraWriteFailed(d, account.ID, err)
			}
			url := browseURL(account, key) + "?focusedCommentId=" + id
			return issueResult(ctx, d, client, account.ID, key, url, "Comment on "+key), nil
		},
	}
}

// ---- transition_jira_issue --------------------------------------------------

type transitionJiraIssueArgs struct {
	AccountID int64  `json:"account_id,omitempty" jsonschema:"connected Jira account id; needed only when the key exists on several sites (see list_jira_projects)"`
	Key       string `json:"key" jsonschema:"issue key, e.g. ABC-123"`
	Status    string `json:"status" jsonschema:"the status to move the issue to, e.g. In Progress or Done (the transition's name also works)"`
	Reason    string `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
}

// reachableTransition fetches the issue's transitions and matches status.
// A miss is a ValidationError naming the reachable statuses.
func reachableTransition(ctx context.Context, client JiraWriteClient, key, status string) (jira.Transition, error) {
	ts, err := client.GetTransitions(ctx, key)
	if err != nil {
		return jira.Transition{}, fmt.Errorf("reading the transitions of %s: %w", key, err)
	}
	t, ok := jira.MatchTransition(ts, status)
	if !ok {
		return jira.Transition{}, &ValidationError{Msg: fmt.Sprintf("no transition of %s leads to %q; reachable now: %s",
			key, strings.TrimSpace(status), strings.Join(jira.TransitionTargets(ts), ", "))}
	}
	return t, nil
}

// NewTransitionJiraIssue builds the transition_jira_issue write tool.
func NewTransitionJiraIssue(factory JiraWriteClientFactory) *Tool {
	return &Tool{
		Name: "transition_jira_issue",
		Description: "Propose moving an existing Jira issue to another status. Pass the target status name; " +
			"the tool rejects a status the issue's workflow cannot reach right now and lists the reachable ones. " +
			"The owner approves it in the chat before anything is sent to Jira.",
		InputSchema: mustWriteSchema[transitionJiraIssueArgs]("transition_jira_issue"),
		Access:      AccessWrite,
		External:    true,
		Surfaces:    []string{"main", "target"},
		Validate: func(ctx context.Context, d *db.DB, raw json.RawMessage) error {
			var a transitionJiraIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if strings.TrimSpace(a.Status) == "" {
				return &ValidationError{Msg: "status is required"}
			}
			_, client, key, err := openIssue(d, factory, a.AccountID, a.Key)
			if err != nil {
				return err
			}
			_, err = reachableTransition(ctx, client, key, a.Status)
			return err
		},
		Normalize: func(_ context.Context, d *db.DB, raw json.RawMessage) (json.RawMessage, error) {
			var a transitionJiraIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return nil, err
			}
			return pinSite(d, raw, a.AccountID, a.Key)
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a transitionJiraIssueArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding transition_jira_issue args: %w", err)
			}
			account, client, key, err := openIssue(d, factory, a.AccountID, a.Key)
			if err != nil {
				return nil, err
			}
			// Re-resolved at apply time: the workflow may have moved since the proposal.
			t, err := reachableTransition(ctx, client, key, a.Status)
			if err != nil {
				return nil, jiraWriteFailed(d, account.ID, err)
			}
			if err := client.TransitionIssue(ctx, key, t.ID); err != nil {
				return nil, jiraWriteFailed(d, account.ID, err)
			}
			return issueResult(ctx, d, client, account.ID, key, browseURL(account, key), key+" → "+t.To.Name), nil
		},
	}
}

// ---- assign_jira_issue ------------------------------------------------------

type assignJiraIssueArgs struct {
	AccountID int64  `json:"account_id,omitempty" jsonschema:"connected Jira account id; needed only when the key exists on several sites (see list_jira_projects)"`
	Key       string `json:"key" jsonschema:"issue key, e.g. ABC-123"`
	Assignee  string `json:"assignee" jsonschema:"me (the owner), a person's email, or their exact display name"`
	Reason    string `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
	// ResolvedAssigneeAccountID/ResolvedAssigneeName are filled in by
	// Normalize when the proposal is recorded, from Assignee at that moment —
	// never by the model, and always overwritten from a fresh resolution
	// regardless of any value already present. Execute uses ONLY these two
	// fields (pinnedAssignee), never Assignee, so the person the owner
	// approved cannot silently change to someone else who later becomes the
	// unique match for the same name/email.
	ResolvedAssigneeAccountID string `json:"resolved_assignee_account_id,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
	ResolvedAssigneeName      string `json:"resolved_assignee_name,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
}

type jiraAssignee struct{ AccountID, Name string }

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

// resolveAssignee maps "me" / an email / a display name to an Atlassian
// account id: owner identity → jira_user_map → Jira user search. client is
// lazy so "me" and a local hit never build one.
func resolveAssignee(ctx context.Context, d *db.DB, account db.JiraAccount, who string, client func() (JiraWriteClient, error)) (jiraAssignee, error) {
	who = strings.TrimSpace(who)
	if strings.EqualFold(who, "me") {
		return ownerAssignee(d, account)
	}
	if a, found, err := localAssignee(d, who); err != nil || found {
		return a, err
	}
	c, err := client()
	if err != nil {
		return jiraAssignee{}, err
	}
	return searchAssignee(ctx, c, who)
}

func ownerAssignee(d *db.DB, account db.JiraAccount) (jiraAssignee, error) {
	if account.OwnerAccountID != "" {
		return jiraAssignee{account.OwnerAccountID, firstNonEmpty(account.OwnerDisplayName, "you")}, nil
	}
	owner, err := d.ResolveOwner()
	if err != nil {
		return jiraAssignee{}, fmt.Errorf("resolving the owner: %w", err)
	}
	if owner.JiraAccountID != "" {
		return jiraAssignee{owner.JiraAccountID, firstNonEmpty(owner.DisplayName, "you")}, nil
	}
	return jiraAssignee{}, &ValidationError{Msg: fmt.Sprintf("the owner's own Jira identity is not recorded yet; "+
		"ask the owner to run 'watchtower jira login --account %d', or pass their email", account.ID)}
}

func localAssignee(d *db.DB, who string) (jiraAssignee, bool, error) {
	maps, err := d.GetJiraUserMaps()
	if err != nil {
		return jiraAssignee{}, false, err
	}
	byEmail := strings.Contains(who, "@")
	var hits []db.JiraUserMap
	for _, m := range maps {
		if (byEmail && strings.EqualFold(m.Email, who)) || (!byEmail && strings.EqualFold(m.DisplayName, who)) {
			hits = append(hits, m)
		}
	}
	switch len(hits) {
	case 0:
		return jiraAssignee{}, false, nil
	case 1:
		return jiraAssignee{hits[0].JiraAccountID, firstNonEmpty(hits[0].DisplayName, hits[0].Email)}, true, nil
	default:
		names := make([]string, 0, len(hits))
		for _, h := range hits {
			names = append(names, strings.TrimSpace(h.DisplayName+" <"+h.Email+">"))
		}
		return jiraAssignee{}, true, &ValidationError{Msg: fmt.Sprintf("%q matches several Jira users (%s); pass an email", who, strings.Join(names, ", "))}
	}
}

func searchAssignee(ctx context.Context, c JiraWriteClient, who string) (jiraAssignee, error) {
	users, err := c.SearchUsers(ctx, who)
	if err != nil {
		return jiraAssignee{}, fmt.Errorf("searching Jira users for %q: %w", who, err)
	}
	people, exact := assignableJiraUsers(users, who)
	pick := func(u jira.User) jiraAssignee {
		return jiraAssignee{u.AccountID, firstNonEmpty(u.DisplayName, u.EmailAddress)}
	}
	switch {
	case len(exact) == 1:
		return pick(exact[0]), nil
	case len(exact) == 0 && len(people) == 1:
		return pick(people[0]), nil
	case len(people) == 0:
		return jiraAssignee{}, &ValidationError{Msg: fmt.Sprintf("no active Jira user matches %q; ask the owner for the person's email", who)}
	}
	names := make([]string, 0, 5)
	for i, u := range people {
		if i == 5 {
			break
		}
		names = append(names, u.DisplayName)
	}
	return jiraAssignee{}, &ValidationError{Msg: fmt.Sprintf("%q matches several Jira users (%s); pass an email", who, strings.Join(names, ", "))}
}

// assignableJiraUsers keeps the active human (atlassian) accounts of a user
// search, and the subset whose email or display name equals who exactly.
func assignableJiraUsers(users []jira.User, who string) (people, exact []jira.User) {
	for _, u := range users {
		if !u.Active || (u.AccountType != "" && u.AccountType != "atlassian") {
			continue
		}
		people = append(people, u)
		if strings.EqualFold(u.EmailAddress, who) || strings.EqualFold(u.DisplayName, who) {
			exact = append(exact, u)
		}
	}
	return people, exact
}

// NewAssignJiraIssue builds the assign_jira_issue write tool.
func NewAssignJiraIssue(factory JiraWriteClientFactory) *Tool {
	return &Tool{
		Name: "assign_jira_issue",
		Description: "Propose assigning an existing Jira issue. assignee is \"me\" (the owner), a person's email, " +
			"or their exact display name; an ambiguous name is rejected with the candidates. The owner approves " +
			"it in the chat before anything is sent to Jira.",
		InputSchema: mustWriteSchema[assignJiraIssueArgs]("assign_jira_issue"),
		Access:      AccessWrite,
		External:    true,
		Surfaces:    []string{"main", "target"},
		Validate: func(ctx context.Context, d *db.DB, raw json.RawMessage) error {
			var a assignJiraIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if strings.TrimSpace(a.Assignee) == "" {
				return &ValidationError{Msg: "assignee is required"}
			}
			account, _, err := resolveIssueTarget(d, a.AccountID, a.Key)
			if err != nil {
				return err
			}
			_, err = resolveAssignee(ctx, d, account, a.Assignee, func() (JiraWriteClient, error) { return factory(account) })
			return err
		},
		Normalize: func(ctx context.Context, d *db.DB, raw json.RawMessage) (json.RawMessage, error) {
			var a assignJiraIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return nil, err
			}
			account, key, err := resolveIssueTarget(d, a.AccountID, a.Key)
			if err != nil {
				return nil, err
			}
			// Resolved fresh from a.Assignee every time — any resolved_* value
			// already present in raw (a replay, or a model that guessed the
			// field name) is discarded, never trusted.
			who, err := resolveAssignee(ctx, d, account, a.Assignee, func() (JiraWriteClient, error) { return factory(account) })
			if err != nil {
				return nil, err
			}
			return mergeJSON(raw, map[string]any{
				"account_id": account.ID, "key": key,
				"resolved_assignee_account_id": who.AccountID,
				"resolved_assignee_name":       who.Name,
			})
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a assignJiraIssueArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding assign_jira_issue args: %w", err)
			}
			account, client, key, err := openIssue(d, factory, a.AccountID, a.Key)
			if err != nil {
				return nil, err
			}
			// Pinned at propose time (Normalize) — never re-derived from
			// Assignee here, so a person who stopped matching the same name
			// or email between propose and apply can never silently receive
			// an assignment the owner approved for someone else.
			who, err := pinnedAssignee(a)
			if err != nil {
				return nil, err
			}
			if err := client.AssignIssue(ctx, key, who.AccountID); err != nil {
				return nil, jiraWriteFailed(d, account.ID, err)
			}
			return issueResult(ctx, d, client, account.ID, key, browseURL(account, key), key+" → "+who.Name), nil
		},
	}
}

// pinnedAssignee reads the assignee Normalize resolved and persisted when
// this action was proposed. A blank ResolvedAssigneeAccountID means Execute
// was reached without going through Propose's Normalize step (every real
// proposal has one; this only happens in a direct test call or a stale row
// predating this pinning) — a clear, actionable error rather than silently
// falling back to re-resolving Assignee, which is exactly the bug this pins.
func pinnedAssignee(a assignJiraIssueArgs) (jiraAssignee, error) {
	if a.ResolvedAssigneeAccountID == "" {
		return jiraAssignee{}, fmt.Errorf("assign_jira_issue: no assignee was resolved when this was proposed; re-propose the action")
	}
	return jiraAssignee{AccountID: a.ResolvedAssigneeAccountID, Name: firstNonEmpty(a.ResolvedAssigneeName, a.ResolvedAssigneeAccountID)}, nil
}

// ---- update_jira_issue ------------------------------------------------------

type updateJiraIssueArgs struct {
	AccountID    int64    `json:"account_id,omitempty" jsonschema:"connected Jira account id; needed only when the key exists on several sites (see list_jira_projects)"`
	Key          string   `json:"key" jsonschema:"issue key, e.g. ABC-123"`
	Summary      string   `json:"summary,omitempty" jsonschema:"new title, at most 255 characters"`
	Priority     string   `json:"priority,omitempty" jsonschema:"Jira priority name, e.g. High"`
	LabelsAdd    []string `json:"labels_add,omitempty" jsonschema:"labels to add (no spaces)"`
	LabelsRemove []string `json:"labels_remove,omitempty" jsonschema:"labels to remove"`
	DueDate      string   `json:"due_date,omitempty" jsonschema:"new due date, YYYY-MM-DD"`
	Reason       string   `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
}

func trimmedLabels(in []string) []string {
	var out []string
	for _, l := range in {
		if l = strings.TrimSpace(l); l != "" {
			out = append(out, l)
		}
	}
	return out
}

func (a updateJiraIssueArgs) update() jira.IssueUpdate {
	var u jira.IssueUpdate
	if s := strings.TrimSpace(a.Summary); s != "" {
		u.Summary = &s
	}
	if p := strings.TrimSpace(a.Priority); p != "" {
		u.Priority = &p
	}
	if due := strings.TrimSpace(a.DueDate); due != "" {
		u.DueDate = &due
	}
	u.LabelsAdd, u.LabelsRemove = trimmedLabels(a.LabelsAdd), trimmedLabels(a.LabelsRemove)
	return u
}

func validateIssueUpdate(u jira.IssueUpdate) error {
	if u.Empty() {
		return &ValidationError{Msg: "pass at least one of summary, priority, labels_add, labels_remove, due_date"}
	}
	if u.Summary != nil && len([]rune(*u.Summary)) > 255 {
		return &ValidationError{Msg: "summary must be at most 255 characters"}
	}
	if u.DueDate != nil {
		if _, err := time.Parse("2006-01-02", *u.DueDate); err != nil {
			return &ValidationError{Msg: fmt.Sprintf("due_date %q must be YYYY-MM-DD", *u.DueDate)}
		}
	}
	for _, l := range append(append([]string{}, u.LabelsAdd...), u.LabelsRemove...) {
		if strings.ContainsAny(l, " \t") {
			return &ValidationError{Msg: fmt.Sprintf("label %q: Jira labels cannot contain spaces", l)}
		}
	}
	return nil
}

// NewUpdateJiraIssue builds the update_jira_issue write tool.
func NewUpdateJiraIssue(factory JiraWriteClientFactory) *Tool {
	return &Tool{
		Name: "update_jira_issue",
		Description: "Propose editing an existing Jira issue: any of summary, priority (by name), labels to add " +
			"or remove, and due date (YYYY-MM-DD). The owner approves it in the chat before anything is sent to Jira.",
		InputSchema: mustWriteSchema[updateJiraIssueArgs]("update_jira_issue"),
		Access:      AccessWrite,
		External:    true,
		Surfaces:    []string{"main", "target"},
		Validate: func(_ context.Context, d *db.DB, raw json.RawMessage) error {
			var a updateJiraIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if err := validateIssueUpdate(a.update()); err != nil {
				return err
			}
			_, _, err := resolveIssueTarget(d, a.AccountID, a.Key)
			return err
		},
		Normalize: func(_ context.Context, d *db.DB, raw json.RawMessage) (json.RawMessage, error) {
			var a updateJiraIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return nil, err
			}
			return pinSite(d, raw, a.AccountID, a.Key)
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a updateJiraIssueArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding update_jira_issue args: %w", err)
			}
			account, client, key, err := openIssue(d, factory, a.AccountID, a.Key)
			if err != nil {
				return nil, err
			}
			if err := client.UpdateIssue(ctx, key, a.update()); err != nil {
				return nil, jiraWriteFailed(d, account.ID, err)
			}
			return issueResult(ctx, d, client, account.ID, key, browseURL(account, key), key+" updated"), nil
		},
	}
}
