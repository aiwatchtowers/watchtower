package linear

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"watchtower/internal/db"
)

// timestampLayout is the layout Linear returns and the watermark is stored in.
// Fixed width, so stored timestamps compare as strings.
const timestampLayout = "2006-01-02T15:04:05.000Z"

// Viewer is the authenticated Linear user and their organization.
type Viewer struct{ UserID, Email, Name, OrgID, OrgName, URLKey string }

// FetchViewer returns the authenticated user and organization.
func (c *Client) FetchViewer(ctx context.Context) (Viewer, error) {
	v, err := c.fetchViewer(ctx)
	if err != nil {
		return Viewer{}, err
	}
	return v.viewer(), nil
}

// FetchViewerWithToken runs one viewer request with a bare access token: no
// token store, no refresh. Login and add use it to identify a fresh token's
// workspace before anything is written to disk.
func FetchViewerWithToken(ctx context.Context, accessToken string) (Viewer, error) {
	body, err := json.Marshal(map[string]any{"query": queryViewer})
	if err != nil {
		return Viewer{}, fmt.Errorf("encoding linear request: %w", err)
	}
	c := &Client{endpoint: graphqlEndpoint, http: &http.Client{Timeout: 30 * time.Second}}
	var v viewerData
	authFailed, err := c.send(ctx, body, accessToken, &v)
	if err != nil {
		return Viewer{}, fmt.Errorf("fetching linear viewer: %w", err)
	}
	if authFailed {
		return Viewer{}, fmt.Errorf("fetching linear viewer: %w: access token rejected", ErrAuthRevoked)
	}
	return v.viewer(), nil
}

func (v viewerData) viewer() Viewer {
	return Viewer{UserID: v.Viewer.ID, Email: v.Viewer.Email, Name: v.Viewer.Name,
		OrgID: v.Viewer.Organization.ID, OrgName: v.Viewer.Organization.Name, URLKey: v.Viewer.Organization.URLKey}
}

func (c *Client) fetchViewer(ctx context.Context) (viewerData, error) {
	var v viewerData
	if err := c.Do(ctx, queryViewer, nil, &v); err != nil {
		return viewerData{}, fmt.Errorf("fetching linear viewer: %w", err)
	}
	return v, nil
}

// Syncer runs incremental passes over the selected teams of one Linear account.
type Syncer struct {
	client       *Client
	db           *db.DB
	accountID    int64
	backfillDays int
	now          func() time.Time
	logger       *log.Logger
}

// NewSyncer creates a syncer for one account; a first pass of a team reaches
// backfillDays back (plus every open issue).
func NewSyncer(client *Client, database *db.DB, accountID int64, backfillDays int) *Syncer {
	return &Syncer{
		client:       client,
		db:           database,
		accountID:    accountID,
		backfillDays: backfillDays,
		now:          time.Now,
		logger:       log.New(os.Stderr, "[linear-sync] ", log.LstdFlags),
	}
}

// AccountID returns the Linear account this syncer serves.
func (s *Syncer) AccountID() int64 { return s.accountID }

// SetLogger replaces the syncer's logger.
func (s *Syncer) SetLogger(l *log.Logger) {
	if l != nil {
		s.logger = l
	}
}

// paginate calls fetch with each page's cursor until hasNextPage is false.
func paginate(ctx context.Context, fetch func(ctx context.Context, after *string) (pageInfo, error)) error {
	var after *string
	for {
		pi, err := fetch(ctx, after)
		if err != nil {
			return err
		}
		if !pi.HasNextPage {
			return nil
		}
		cur := pi.EndCursor
		after = &cur
	}
}

// Sync runs one pass over every selected team; returns issues upserted. A team
// error is recorded on that team and the pass continues; ErrAuthRevoked aborts
// the pass at once. Returns the first error seen.
func (s *Syncer) Sync(ctx context.Context) (int, error) {
	if err := s.refreshTeams(ctx); err != nil {
		return 0, err
	}
	teams, err := s.db.ListLinearTeams(s.accountID)
	if err != nil {
		return 0, err
	}
	preWatermark, err := s.oldestSelectedWatermark(teams)
	if err != nil {
		return 0, err
	}
	total, firstErr, err := s.syncSelectedTeams(ctx, teams)
	if err != nil {
		return total, err
	}
	if err := s.reconcileMoved(ctx, teams, preWatermark); err != nil {
		s.logger.Printf("moved issues: %v", err)
		if errors.Is(err, ErrAuthRevoked) || ctx.Err() != nil {
			return total, err
		}
		if firstErr == nil {
			firstErr = err
		}
	}
	if err := s.syncUsers(ctx); err != nil {
		if errors.Is(err, ErrAuthRevoked) {
			return total, err
		}
		s.logger.Printf("users: %v", err)
		if firstErr == nil {
			firstErr = err
		}
	}
	if err := s.resolveIdentities(); err != nil && firstErr == nil {
		firstErr = err
	}
	return total, firstErr
}

// syncSelectedTeams syncs every selected team. A team error is recorded on
// that team and kept as firstErr; ErrAuthRevoked or a cancelled context stops
// the loop and comes back as abort.
func (s *Syncer) syncSelectedTeams(ctx context.Context, teams []db.LinearTeam) (total int, firstErr, abort error) {
	for _, t := range teams {
		if !t.IsSelected {
			continue
		}
		n, err := s.syncTeam(ctx, t)
		total += n
		if err == nil {
			continue
		}
		s.logger.Printf("team %s: %v", t.Key, err)
		if rerr := s.db.RecordLinearSyncError(s.accountID, t.ID, err.Error()); rerr != nil {
			s.logger.Printf("team %s: %v", t.Key, rerr)
		}
		if errors.Is(err, ErrAuthRevoked) || ctx.Err() != nil {
			return total, firstErr, err
		}
		if firstErr == nil {
			firstErr = err
		}
	}
	return total, firstErr, nil
}

// resolveIdentities maps Linear users to Slack by email and stamps the Slack
// ids on the account's issues; only the stamping failure is returned.
func (s *Syncer) resolveIdentities() error {
	if _, err := s.db.ResolveLinearUsersByEmail(time.Now().UTC().Format(time.RFC3339)); err != nil {
		s.logger.Printf("%v", err)
	}
	if _, err := s.db.BackfillLinearSlackIDs(s.accountID); err != nil {
		s.logger.Printf("%v", err)
		return err
	}
	return nil
}

// refreshTeams stores every team of the organization; teams the viewer belongs
// to start selected, the owner's choice on known teams is kept.
func (s *Syncer) refreshTeams(ctx context.Context) error {
	v, err := s.client.fetchViewer(ctx)
	if err != nil {
		return err
	}
	selectNew := map[string]bool{}
	for _, t := range v.Viewer.Teams.Nodes {
		selectNew[t.ID] = true
	}
	var teams []db.LinearTeam
	err = paginate(ctx, func(ctx context.Context, after *string) (pageInfo, error) {
		var out teamsData
		if err := s.client.Do(ctx, queryTeams, map[string]any{"after": after}, &out); err != nil {
			return pageInfo{}, fmt.Errorf("fetching linear teams: %w", err)
		}
		for _, t := range out.Teams.Nodes {
			teams = append(teams, db.LinearTeam{AccountID: s.accountID, ID: t.ID, Key: t.Key, Name: t.Name})
		}
		return out.Teams.PageInfo, nil
	})
	if err != nil {
		return err
	}
	return s.db.UpsertLinearTeams(s.accountID, teams, selectNew)
}

// syncTeam fetches the team's issues, comments and planning; the watermark
// moves only when all three succeed.
func (s *Syncer) syncTeam(ctx context.Context, t db.LinearTeam) (int, error) {
	st, err := s.db.GetLinearSyncState(s.accountID, t.ID)
	if err != nil {
		return 0, err
	}
	now := s.now().UTC()
	firstPass := st.Watermark == ""
	since := st.Watermark
	if firstPass {
		since = now.AddDate(0, 0, -s.backfillDays).Format(timestampLayout)
	}
	// The watermark is the newest issue updatedAt, never below since: a quiet
	// team records the since it queried with, so its next pass is incremental.
	// Comments do not raise it: they are fetched after the issues, so a later
	// comment would push the watermark past an issue change made mid-pass.
	maxUpdated := since
	n, err := s.syncIssues(ctx, issueFilter(t.ID, since, firstPass), &maxUpdated)
	if err != nil {
		return n, fmt.Errorf("syncing issues of linear team %s: %w", t.Key, err)
	}
	if err := s.syncComments(ctx, t, since); err != nil {
		return n, fmt.Errorf("syncing comments of linear team %s: %w", t.Key, err)
	}
	if err := s.syncPlanning(ctx, t); err != nil {
		return n, fmt.Errorf("syncing planning of linear team %s: %w", t.Key, err)
	}
	if err := s.db.RecordLinearSyncSuccess(s.accountID, t.ID, maxUpdated, now.Format(timestampLayout)); err != nil {
		return n, err
	}
	return n, nil
}

// oldestSelectedWatermark is the oldest watermark among the selected teams,
// or empty when none has one yet.
func (s *Syncer) oldestSelectedWatermark(teams []db.LinearTeam) (string, error) {
	since := ""
	for _, t := range teams {
		if !t.IsSelected {
			continue
		}
		st, err := s.db.GetLinearSyncState(s.accountID, t.ID)
		if err != nil {
			return "", err
		}
		if st.Watermark != "" && (since == "" || st.Watermark < since) {
			since = st.Watermark
		}
	}
	return since, nil
}

// reconcileChunk bounds the id list of one reconcile issues request.
const reconcileChunk = 50

// reconcileMoved refreshes stored issues that now live outside the selected
// teams: an issue moved to an unselected team no longer matches any team
// filter, so it is found account-wide by id among the issues changed since
// the account's moved watermark. Issues of unselected teams that were never
// stored are not fetched. The moved watermark advances to the oldest selected
// team watermark only on success, so a failed reconcile is retried from the
// same point though the team watermarks moved on. Before the first reconcile
// it starts at fallback (the oldest selected watermark before this pass;
// empty on a first pass, when nothing stored can have moved yet).
func (s *Syncer) reconcileMoved(ctx context.Context, teams []db.LinearTeam, fallback string) error {
	since, err := s.db.GetLinearMovedWatermark(s.accountID)
	if err != nil {
		return err
	}
	if since == "" {
		since = fallback
	}
	if since != "" {
		if err := s.refreshMovedSince(ctx, teams, since); err != nil {
			return err
		}
	}
	next, err := s.oldestSelectedWatermark(teams)
	if err != nil || next == "" {
		return err
	}
	return s.db.SetLinearMovedWatermark(s.accountID, next)
}

func (s *Syncer) refreshMovedSince(ctx context.Context, teams []db.LinearTeam, since string) error {
	selected := []string{}
	for _, t := range teams {
		if t.IsSelected {
			selected = append(selected, t.ID)
		}
	}
	filter := map[string]any{
		"team":      map[string]any{"id": map[string]any{"nin": selected}},
		"updatedAt": map[string]any{"gte": since},
	}
	var changed []string
	err := paginate(ctx, func(ctx context.Context, after *string) (pageInfo, error) {
		var out issueIDsData
		if err := s.client.Do(ctx, queryIssueIDs, map[string]any{"filter": filter, "after": after}, &out); err != nil {
			return pageInfo{}, fmt.Errorf("listing changed linear issues outside the selected teams: %w", err)
		}
		for _, n := range out.Issues.Nodes {
			changed = append(changed, n.ID)
		}
		return out.Issues.PageInfo, nil
	})
	if err != nil {
		return err
	}
	known, err := s.db.KnownLinearIssueIDs(s.accountID, changed)
	if err != nil {
		return err
	}
	for start := 0; start < len(known); start += reconcileChunk {
		ids := known[start:min(start+reconcileChunk, len(known))]
		byID := map[string]any{"id": map[string]any{"in": ids}}
		unused := since
		if _, err := s.syncIssues(ctx, byID, &unused); err != nil {
			return fmt.Errorf("refreshing moved linear issues: %w", err)
		}
		comments := map[string]any{"issue": byID, "updatedAt": map[string]any{"gte": since}}
		if err := s.syncCommentsMatching(ctx, comments); err != nil {
			return fmt.Errorf("refreshing comments of moved linear issues: %w", err)
		}
	}
	return nil
}

func issueFilter(teamID, since string, firstPass bool) map[string]any {
	f := map[string]any{"team": map[string]any{"id": map[string]any{"eq": teamID}}}
	changed := map[string]any{"updatedAt": map[string]any{"gte": since}}
	if !firstPass {
		f["updatedAt"] = changed["updatedAt"]
		return f
	}
	f["or"] = []any{changed, map[string]any{"state": map[string]any{"type": map[string]any{"nin": []string{"completed", "canceled"}}}}}
	return f
}

func keepMax(cur *string, v string) {
	if v > *cur {
		*cur = v
	}
}

func (s *Syncer) syncIssues(ctx context.Context, filter map[string]any, maxUpdated *string) (int, error) {
	count := 0
	err := paginate(ctx, func(ctx context.Context, after *string) (pageInfo, error) {
		var out issuesData
		if err := s.client.Do(ctx, queryIssues, map[string]any{"filter": filter, "after": after}, &out); err != nil {
			return pageInfo{}, err
		}
		for _, raw := range out.Issues.Nodes {
			var n issueNodeJSON
			if err := json.Unmarshal(raw, &n); err != nil {
				return pageInfo{}, fmt.Errorf("decoding linear issue: %w", err)
			}
			n.raw = raw
			if err := s.storeIssue(n); err != nil {
				return pageInfo{}, err
			}
			count++
			keepMax(maxUpdated, n.UpdatedAt)
		}
		return out.Issues.PageInfo, nil
	})
	return count, err
}

func (s *Syncer) storeIssue(n issueNodeJSON) error {
	if err := s.db.UpsertLinearIssue(mapIssue(s.accountID, n)); err != nil {
		return err
	}
	if err := s.db.UpsertLinearHistory(mapHistory(s.accountID, n)); err != nil {
		return err
	}
	return s.db.ReplaceLinearRelations(s.accountID, n.ID, mapRelations(n))
}

func (s *Syncer) syncComments(ctx context.Context, t db.LinearTeam, since string) error {
	return s.syncCommentsMatching(ctx, map[string]any{
		"issue":     map[string]any{"team": map[string]any{"id": map[string]any{"eq": t.ID}}},
		"updatedAt": map[string]any{"gte": since},
	})
}

func (s *Syncer) syncCommentsMatching(ctx context.Context, filter map[string]any) error {
	return paginate(ctx, func(ctx context.Context, after *string) (pageInfo, error) {
		var out commentsData
		if err := s.client.Do(ctx, queryComments, map[string]any{"filter": filter, "after": after}, &out); err != nil {
			return pageInfo{}, err
		}
		for _, c := range out.Comments.Nodes {
			if c.Issue == nil { // not an issue comment; the filter should never return one
				continue
			}
			if err := s.db.UpsertLinearComment(mapComment(s.accountID, c)); err != nil {
				return pageInfo{}, err
			}
		}
		return out.Comments.PageInfo, nil
	})
}

func (s *Syncer) syncPlanning(ctx context.Context, t db.LinearTeam) error {
	var out planningData
	if err := s.client.Do(ctx, queryTeamPlanning, map[string]any{"team": t.ID}, &out); err != nil {
		return err
	}
	cycles := make([]db.LinearCycle, 0, len(out.Team.Cycles.Nodes))
	for _, c := range out.Team.Cycles.Nodes {
		cycles = append(cycles, mapCycle(s.accountID, t.ID, c))
	}
	if err := s.db.UpsertLinearCycles(cycles); err != nil {
		return err
	}
	projects := make([]db.LinearProject, 0, len(out.Team.Projects.Nodes))
	for _, p := range out.Team.Projects.Nodes {
		projects = append(projects, mapProject(s.accountID, p))
	}
	return s.db.UpsertLinearProjects(projects)
}

func (s *Syncer) syncUsers(ctx context.Context) error {
	return paginate(ctx, func(ctx context.Context, after *string) (pageInfo, error) {
		var out usersData
		if err := s.client.Do(ctx, queryUsers, map[string]any{"after": after}, &out); err != nil {
			return pageInfo{}, fmt.Errorf("fetching linear users: %w", err)
		}
		users := make([]db.LinearUser, 0, len(out.Users.Nodes))
		for _, u := range out.Users.Nodes {
			users = append(users, mapUser(u))
		}
		if err := s.db.UpsertLinearUsers(users); err != nil {
			return pageInfo{}, err
		}
		return out.Users.PageInfo, nil
	})
}

// --- pure node → row mapping ---

func str(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func idOf(p *idName) string {
	if p == nil {
		return ""
	}
	return p.ID
}

func nameOf(p *idName) string {
	if p == nil {
		return ""
	}
	return p.Name
}

// stateChangedAt is when the issue's status category last changed, as Jira's
// statuscategorychangedate: the newest history entry that moved it to another
// category (a move within one category does not count), else the timestamp
// of the current category (startedAt, completedAt or canceledAt), else empty.
func stateChangedAt(n issueNodeJSON) string {
	latest := ""
	for _, h := range n.History.Nodes {
		if h.ToState == nil {
			continue
		}
		if h.FromState == nil || StatusCategory(h.FromState.Type) != StatusCategory(h.ToState.Type) {
			keepMax(&latest, h.CreatedAt)
		}
	}
	if latest != "" {
		return latest
	}
	switch n.State.Type {
	case "started":
		return str(n.StartedAt)
	case "completed":
		return str(n.CompletedAt)
	case "canceled":
		return str(n.CanceledAt)
	}
	return ""
}

func mapIssue(accountID int64, n issueNodeJSON) db.LinearIssue {
	i := db.LinearIssue{
		AccountID:       accountID,
		ID:              n.ID,
		Key:             n.Identifier,
		PreviousKeys:    n.PreviousIdentifiers,
		TeamID:          n.Team.ID,
		TeamKey:         n.Team.Key,
		Title:           n.Title,
		DescriptionText: str(n.Description),
		StateName:       n.State.Name,
		StateType:       n.State.Type,
		StatusCategory:  StatusCategory(n.State.Type),
		StateChangedAt:  stateChangedAt(n),
		Priority:        int(n.Priority),
		Estimate:        n.Estimate,
		DueDate:         str(n.DueDate),
		CycleID:         idOf(n.Cycle),
		ProjectID:       idOf(n.Project),
		ParentID:        idOf(n.Parent),
		URL:             n.URL,
		CreatedAt:       n.CreatedAt,
		UpdatedAt:       n.UpdatedAt,
		CompletedAt:     str(n.CompletedAt),
		CanceledAt:      str(n.CanceledAt),
		RawJSON:         string(n.raw),
		IsDeleted:       n.ArchivedAt != nil || (n.Trashed != nil && *n.Trashed),
	}
	if n.Assignee != nil {
		i.AssigneeID, i.AssigneeEmail, i.AssigneeDisplayName = n.Assignee.ID, n.Assignee.Email, n.Assignee.Name
	}
	if n.Creator != nil {
		i.CreatorID, i.CreatorEmail, i.CreatorDisplayName = n.Creator.ID, n.Creator.Email, n.Creator.Name
	}
	for _, l := range n.Labels.Nodes {
		i.Labels = append(i.Labels, l.Name)
	}
	return i
}

// mapHistory turns history nodes into status and assignee entries; one node
// can yield both.
func mapHistory(accountID int64, n issueNodeJSON) []db.LinearHistoryEntry {
	var out []db.LinearHistoryEntry
	for _, h := range n.History.Nodes {
		base := db.LinearHistoryEntry{AccountID: accountID, ID: h.ID, IssueID: n.ID,
			ActorID: idOf(h.Actor), ActorDisplayName: nameOf(h.Actor), ChangedAt: h.CreatedAt}
		if h.ToState != nil {
			e := base
			e.Field = "status"
			if h.FromState != nil {
				e.FromValue, e.FromString = h.FromState.ID, h.FromState.Name
			}
			e.ToValue, e.ToString = h.ToState.ID, h.ToState.Name
			out = append(out, e)
		}
		if h.FromAssignee != nil || h.ToAssignee != nil {
			e := base
			e.Field = "assignee"
			e.FromValue, e.FromString = idOf(h.FromAssignee), nameOf(h.FromAssignee)
			e.ToValue, e.ToString = idOf(h.ToAssignee), nameOf(h.ToAssignee)
			out = append(out, e)
		}
	}
	return out
}

// mapRelations keeps the relation types the tracker views understand.
func mapRelations(n issueNodeJSON) []db.LinearRelation {
	var out []db.LinearRelation
	for _, r := range n.Relations.Nodes {
		switch r.Type {
		case "blocks", "related", "duplicate":
		default:
			continue
		}
		if r.RelatedIssue == nil {
			continue
		}
		out = append(out, db.LinearRelation{ID: r.ID, RelatedIssueID: r.RelatedIssue.ID, Type: r.Type})
	}
	return out
}

func mapComment(accountID int64, c commentNodeJSON) db.LinearComment {
	return db.LinearComment{
		AccountID:         accountID,
		ID:                c.ID,
		IssueID:           c.Issue.ID,
		IssueKey:          c.Issue.Identifier,
		AuthorID:          idOf(c.User),
		AuthorDisplayName: nameOf(c.User),
		BodyText:          c.Body,
		MentionedUserIDs:  MentionedUserIDs(str(c.BodyData)),
		CreatedAt:         c.CreatedAt,
		UpdatedAt:         c.UpdatedAt,
	}
}

func mapCycle(accountID int64, teamID string, c cycleNode) db.LinearCycle {
	return db.LinearCycle{AccountID: accountID, ID: c.ID, TeamID: teamID, Number: int(c.Number), Name: str(c.Name),
		StartsAt: c.StartsAt, EndsAt: c.EndsAt, CompletedAt: str(c.CompletedAt), Progress: c.Progress}
}

func mapProject(accountID int64, p projectNode) db.LinearProject {
	return db.LinearProject{AccountID: accountID, ID: p.ID, Name: p.Name, State: p.State, Progress: p.Progress,
		TargetDate: str(p.TargetDate), LeadID: idOf(p.Lead), URL: p.URL}
}

func mapUser(u userNode) db.LinearUser {
	name := u.Name
	if name == "" {
		name = u.DisplayName
	}
	return db.LinearUser{ID: u.ID, Email: u.Email, DisplayName: name}
}
