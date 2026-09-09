package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// JiraBoardClient is the board-discovery slice connect_jira_board needs — a
// seam so tests inject a fake and the CLI wiring injects a real per-account
// *jira.Client. FetchAllBoards returns every agile board on the site; the tool
// matches the owner's project/name against that live list.
type JiraBoardClient interface {
	FetchAllBoards(ctx context.Context) ([]jira.Board, error)
}

// JiraBoardProfiler is the BoardAnalyzer slice: it profiles one selected board
// and writes the profile columns itself. *jira.BoardAnalyzer satisfies it.
type JiraBoardProfiler interface {
	AnalyzeBoard(ctx context.Context, board db.JiraBoard) (*jira.BoardProfile, error)
}

// JiraConnect bundles the per-account dependencies connect_jira_board's Apply
// needs: a board client (required) and an optional profiler. The profiler is
// best-effort — a nil one, or one that fails, never fails the connect.
type JiraConnect struct {
	Client   JiraBoardClient
	Profiler JiraBoardProfiler
}

// JiraConnectFactory builds the connect dependencies for one connected account.
type JiraConnectFactory func(account db.JiraAccount) (JiraConnect, error)

type connectJiraBoardArgs struct {
	AccountID  int64  `json:"account_id,omitempty" jsonschema:"connected Jira account id; required only when more than one site is connected (see list_jira_projects)"`
	ProjectKey string `json:"project_key" jsonschema:"project key of the board to connect, e.g. ABC — need not be synced yet"`
	BoardName  string `json:"board_name,omitempty" jsonschema:"board name to disambiguate when the project has several boards"`
	Reason     string `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
}

// matchBoard finds the one board in the site's live board list that the owner
// named. A project with several boards and no board_name is ambiguous rather
// than an arbitrary pick; a name that matches nothing is a miss the owner sees.
func matchBoard(boards []jira.Board, projectKey, boardName string) (jira.Board, error) {
	pk := strings.ToUpper(strings.TrimSpace(projectKey))
	name := strings.TrimSpace(boardName)
	var matches []jira.Board
	for _, b := range boards {
		if !strings.EqualFold(strings.TrimSpace(b.Location.ProjectKey), pk) {
			continue
		}
		if name != "" && !strings.EqualFold(strings.TrimSpace(b.Name), name) {
			continue
		}
		matches = append(matches, b)
	}
	switch len(matches) {
	case 1:
		return matches[0], nil
	case 0:
		if name != "" {
			return jira.Board{}, fmt.Errorf("no board named %q in project %s on this site — check the board name on the Jira site", name, pk)
		}
		// Deliberately NOT "call list_jira_projects": that lists only *synced*
		// projects, and connect exists precisely to reach an un-synced one.
		return jira.Board{}, fmt.Errorf("no board found for project %s on this site — check the project key on the Jira site", pk)
	default:
		names := make([]string, len(matches))
		for i, b := range matches {
			names[i] = b.Name
		}
		return jira.Board{}, fmt.Errorf("project %s has several boards (%s) — pass board_name to choose one", pk, strings.Join(names, ", "))
	}
}

// NewConnectJiraBoard builds the connect_jira_board write tool: it starts
// watching a Jira board so the daemon syncs its issues and it appears in
// digests and dashboards. External (it selects a board against the live site)
// and main-chat only — connecting work is not the target chat's mandate.
func NewConnectJiraBoard(factory JiraConnectFactory) *Tool {
	schema, err := jsonschema.For[connectJiraBoardArgs](nil)
	if err != nil {
		panic("connect_jira_board schema: " + err.Error())
	}
	return &Tool{
		Name: "connect_jira_board",
		Description: "Propose connecting a Jira board so Watchtower starts watching its issues and it shows up in " +
			"digests and dashboards. The owner approves it in the chat before anything is selected. Use it when the " +
			"owner asks to start tracking a project or board that is not yet watched; when the project has several " +
			"boards, pass board_name, and when the project is ambiguous, ask the owner instead of guessing.",
		InputSchema: schema,
		Access:      AccessWrite,
		External:    true,
		Surfaces:    []string{"main"},
		Validate: func(_ context.Context, d *db.DB, raw json.RawMessage) error {
			var a connectJiraBoardArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if strings.TrimSpace(a.ProjectKey) == "" {
				return &ValidationError{Msg: "project_key is required"}
			}
			// Deliberately NOT projectSynced (unlike create_jira_issue): the whole
			// point of connect is to watch a project that is not synced yet.
			if _, err := ResolveJiraAccount(d, a.AccountID); err != nil {
				return err
			}
			return nil
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a connectJiraBoardArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding connect_jira_board args: %w", err)
			}
			account, err := ResolveJiraAccount(d, a.AccountID)
			if err != nil {
				return nil, err
			}
			conn, err := factory(account)
			if err != nil {
				return nil, err
			}
			boards, err := conn.Client.FetchAllBoards(ctx)
			if err != nil {
				// Same auth-revoked side write as create_jira_issue: a revoked
				// grant is the account's problem and the owner must see it, and
				// if recording it fails the primary error still rides out.
				if errors.Is(err, jira.ErrAuthRevoked) {
					if dbErr := d.SetJiraAccountAuthState(account.ID, "revoked", err.Error()); dbErr != nil {
						return nil, fmt.Errorf("%w (and recording the revoked state failed: %v)", err, dbErr)
					}
				}
				return nil, err
			}
			board, err := matchBoard(boards, a.ProjectKey, a.BoardName)
			if err != nil {
				return nil, err
			}
			// Upsert first so the row exists, then select it. UpsertJiraBoard
			// preserves is_selected (and the profile columns) on conflict, so
			// the DB side of a re-connect is idempotent; the profiler below is
			// cache-protected too, so a reconnect stays cheap.
			row := db.JiraBoard{
				AccountID: account.ID, ID: board.ID, Name: board.Name,
				ProjectKey: board.Location.ProjectKey, BoardType: board.Type,
				SyncedAt: time.Now().UTC().Format(time.RFC3339),
			}
			if err := d.UpsertJiraBoard(row); err != nil {
				return nil, fmt.Errorf("saving board %d: %w", board.ID, err)
			}
			if err := d.SetJiraBoardSelected(account.ID, board.ID, true); err != nil {
				return nil, fmt.Errorf("selecting board %d: %w", board.ID, err)
			}
			result := map[string]any{
				"board_id": board.ID, "board_name": board.Name, "project_key": row.ProjectKey,
			}
			// The board is connected the moment it is selected — the next daemon
			// sync pass reads GetJiraSelectedBoards and pulls its issues, so we
			// never block on that here. Profiling is a best-effort enrichment on
			// top: the daemon's auto-refresh only re-profiles boards that already
			// have a profile, so this inline pass bootstraps the first one — but
			// its failure (or a nil profiler) must never fail the connect.
			if conn.Profiler != nil {
				// Hand the profiler the PERSISTED row, not the freshly-built one:
				// AnalyzeBoard skips the (paid, strong-tier) LLM pass only when the
				// row already carries a matching config_hash + profile, so a
				// reconnect of an already-profiled, unchanged board is a cache hit
				// instead of a fresh analysis — the same fetch CheckAndRefreshProfiles
				// and 'jira boards analyze' do before calling AnalyzeBoard.
				profiled := row
				if full, ferr := d.GetJiraBoardProfile(account.ID, board.ID); ferr == nil && full != nil {
					profiled = *full
				}
				if _, err := conn.Profiler.AnalyzeBoard(ctx, profiled); err != nil {
					warning := "connected, but the board profile was not generated (retry with 'watchtower jira boards analyze'): " + err.Error()
					// A revoked grant surfacing here is the same account-level
					// problem the FetchAllBoards path escalates — record it (still
					// without failing the connect) so the owner is not left chasing
					// a phantom profiling error while the account card reads OK.
					if errors.Is(err, jira.ErrAuthRevoked) {
						if dbErr := d.SetJiraAccountAuthState(account.ID, "revoked", err.Error()); dbErr != nil {
							warning += " (and recording the revoked grant failed: " + dbErr.Error() + ")"
						}
					}
					result["warning"] = warning
				}
			}
			return result, nil
		},
	}
}
