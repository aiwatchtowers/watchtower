package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
	"watchtower/internal/sessionmsg"
	"watchtower/internal/workbenchfolders"
)

// Sub-session limits (spec 2026-11-18 §6.5): a sub-session nests at most
// MaxSubSessionDepth below its root session, and at most MaxLiveSubSessions
// sub-sessions — grandchildren included — are live under one root.
const (
	MaxSubSessionDepth = 3
	MaxLiveSubSessions = 6
)

// CodeLimit is start_session's refusal of a sub-session past a limit.
const CodeLimit = "limit"

// maxBriefRunes caps start_session's brief (the header comes on top).
const maxBriefRunes = 20000

// maxSessionTitleRunes caps start_session's title.
const maxSessionTitleRunes = 200

// maxChain bounds a walk along parent_session_id links.
const maxChain = 64

// startingSQL is true for a row whose start has not reached the host yet:
// no state reported, no failure recorded (a failed start writes 'waiting'),
// created within the detached finish's budget. Such a row counts as live,
// so a burst of starts cannot pass the limit before the first one launches.
const startingSQL = `(agent_state IS NULL AND created_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-3 minutes'))`

// errNoStartSession refuses start_session outside a Watchtower terminal
// session of the bound workbench: a sub-session needs a parent.
var errNoStartSession = &ValidationError{Msg: "start_session needs a Watchtower terminal session"}

// startTurn serialises this process's sub-session starts from the limit
// check until the row is written, so parallel calls of one agent cannot
// all pass the limit.
var startTurn sync.Mutex

// runs is m.Runs, or a refusal when there is none.
func (m SessionDeps) runs(ctx context.Context) (map[int64]bool, error) {
	if m.Runs == nil {
		return nil, errors.New("the session host cannot be reached from this process")
	}
	return m.Runs(ctx)
}

type startSessionArgs struct {
	Folder   string `json:"folder" jsonschema:"the bench folder to start in: its name, id or path (workbench_info lists them)"`
	Brief    string `json:"brief" jsonschema:"the sub-session's task, at most 20000 characters; it starts after a fixed header naming you as its parent"`
	Title    string `json:"title,omitempty" jsonschema:"the session's title (optional, at most 200 characters)"`
	TargetID int64  `json:"target_id,omitempty" jsonschema:"the target the sub-session works on (optional)"`
	Agent    string `json:"agent,omitempty" jsonschema:"claude or codex (default: the agent of this session)"`
	Reason   string `json:"reason" jsonschema:"one sentence: why this work goes to a sub-session"`
}

// startSessionResult is start_session's answer: folder is the folder's
// stored name; place the placement asked for (auto: the folder, or its own
// worktree when an agent already works there); worktree the worktree's path
// once the session is placed in one, else "" (placement finishes after the
// answer).
type startSessionResult struct {
	SessionID int64  `json:"session_id"`
	Folder    string `json:"folder"`
	Place     string `json:"place"`
	Worktree  string `json:"worktree"`
}

// NewStartSession starts a sub-session of the calling terminal session in a
// bench folder (spec 2026-11-18 §6.5): `workbench session start --folder F
// --parent <caller>`, the CLI's one start path, with the brief behind the
// fixed sub-session header.
func NewStartSession(sessionEnv func() string, deps SessionDeps) *Tool {
	return &Tool{
		Name: "start_session",
		Description: "Start a sub-session: another agent session of this workbench, in one of its folders, that works on " +
			"the brief you give it. It returns at once with {session_id, folder, place, worktree}; the session " +
			"launches in the background. The sub-session's brief starts with a header naming you as its parent; it " +
			"can message you with send_to_session and its finish_session summary is sent to you. If its launch " +
			"fails you get a line `[Message to #<id> not delivered: the sub-session did not start: …]`. Limits: " +
			"sub-sessions nest at most 3 deep and at most 6 are live under one root session (`limit`). A folder " +
			"without Watchtower's install is refused (`not_installed`). Applied immediately.",
		InputSchema: mustSchema[startSessionArgs]("start_session"),
		Access:      AccessWrite,
		Surfaces:    workbenchSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a startSessionArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if strings.TrimSpace(a.Folder) == "" {
				return &ValidationError{Msg: "folder is required"}
			}
			if err := requireText("brief", a.Brief, maxBriefRunes); err != nil {
				return err
			}
			if len([]rune(strings.TrimSpace(a.Title))) > maxSessionTitleRunes {
				return &ValidationError{Msg: fmt.Sprintf("title must be at most %d characters", maxSessionTitleRunes)}
			}
			if a.TargetID < 0 {
				return &ValidationError{Msg: "target_id must be positive"}
			}
			return validateEnum("agent", a.Agent, string(agentkind.Claude), string(agentkind.Codex))
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a startSessionArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			parent, _, err := startPlan(ctx, d, b, sessionEnv, a)
			if err != nil {
				return err
			}
			// Checked here so a refusal writes no row, and again in Execute
			// under the start turn.
			return checkSubSessionLimits(ctx, d, deps, parent.ID)
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a startSessionArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding start_session args: %w", err)
			}
			if deps.StartSession == nil {
				return nil, errors.New("sub-sessions cannot be started from this process")
			}
			parent, folder, err := startPlan(ctx, d, call.Binding, sessionEnv, a)
			if err != nil {
				return nil, err
			}
			startTurn.Lock()
			defer startTurn.Unlock()
			if err := checkSubSessionLimits(ctx, d, deps, parent.ID); err != nil {
				return nil, err
			}
			parentFolder, err := sessionmsg.FolderName(ctx, d, parent)
			if err != nil {
				return nil, err //nolint:wrapcheck // FolderName names the session
			}
			brief := sessionmsg.SubSessionHeader(parent.ID, parent.Title, parentFolder) + "\n\n" + strings.TrimSpace(a.Brief)
			out, err := deps.StartSession(ctx, startArgs(call.Binding.WorkbenchID, parent, folder, a), brief)
			return startAnswer(out, err)
		},
	}
}

// startPlan is start_session's checks before any start: the calling
// session (the parent), the folder (not_found, folder_removed) and the
// target on this workbench's board. It answers the parent's row and the
// folder.
func startPlan(ctx context.Context, d *db.DB, b Binding, sessionEnv func() string, a startSessionArgs) (*db.TerminalSession, db.WorkbenchFolder, error) {
	p, err := workbenchOf(ctx, d, b)
	if err != nil {
		return nil, db.WorkbenchFolder{}, err
	}
	parent, err := terminalSessionRow(d, p.ID, sessionEnv)
	if err != nil {
		return nil, db.WorkbenchFolder{}, err
	}
	if parent == nil {
		return nil, db.WorkbenchFolder{}, errNoStartSession
	}
	folder, err := workbenchfolders.Resolve(ctx, d, p.ID, a.Folder)
	if err != nil {
		return nil, db.WorkbenchFolder{}, refusalAsValidation(err)
	}
	if a.TargetID > 0 {
		if _, err := targetInWorkbench(d, p.ID, a.TargetID); err != nil {
			return nil, db.WorkbenchFolder{}, err
		}
	}
	return parent, folder, nil
}

// startArgs is the `workbench session start` command line of a sub-session:
// the folder by id (unambiguous), the parent, the agent (default the
// parent's), the brief on stdin and the JSON answer.
func startArgs(wb int64, parent *db.TerminalSession, folder db.WorkbenchFolder, a startSessionArgs) []string {
	agent := a.Agent
	if agent == "" {
		agent = parent.Kind
	}
	args := []string{"--workbench", strconv.FormatInt(wb, 10), "--folder", strconv.FormatInt(folder.ID, 10),
		"--parent", strconv.FormatInt(parent.ID, 10), "--agent", agent, "--brief-stdin", "--json"}
	if t := strings.TrimSpace(a.Title); t != "" {
		args = append(args, "--title", t)
	}
	if a.TargetID > 0 {
		args = append(args, "--target", strconv.FormatInt(a.TargetID, 10))
	}
	return args
}

// cliStartAnswer is the JSON `workbench session start --json` prints: a
// started row, a refusal (ok false, "<code>: <sentence>"), or the Desktop's
// pinned agent-not-found answer (error, agent).
type cliStartAnswer struct {
	OK        bool   `json:"ok"`
	SessionID int64  `json:"session_id"`
	Folder    string `json:"folder"`
	Place     string `json:"place"`
	Worktree  string `json:"worktree"`
	ErrorCode string `json:"error_code"`
	Error     string `json:"error"`
	Agent     string `json:"agent"`
}

// startAnswer reads the start's answer: its result, a refusal as the
// model-facing error, or the start's own failure (a session host that
// cannot be reached leaves no row and comes back here).
func startAnswer(out []byte, runErr error) (any, error) {
	var a cliStartAnswer
	if jerr := json.Unmarshal(out, &a); jerr == nil {
		switch {
		case a.OK && a.SessionID > 0:
			return startSessionResult{SessionID: a.SessionID, Folder: a.Folder, Place: a.Place, Worktree: a.Worktree}, nil
		case a.ErrorCode != "" && a.Error != "":
			return nil, &ValidationError{Msg: a.Error}
		case a.Error == "agent_not_found":
			return nil, &ValidationError{Msg: fmt.Sprintf("agent_not_found: %s is not installed on this Mac.", a.Agent)}
		}
	}
	if runErr != nil {
		return nil, fmt.Errorf("starting the sub-session: %w", runErr)
	}
	return nil, errors.New("starting the sub-session: the start gave no answer")
}

// checkSubSessionLimits refuses a sub-session of parent past a limit: one
// nesting level too deep under its root, or MaxLiveSubSessions live under
// the root already. The tree is counted through every level: a
// grandchild's sub-sessions count under the root, and a session whose
// parent was deleted is a root of its own.
func checkSubSessionLimits(ctx context.Context, d *db.DB, deps SessionDeps, parent int64) error {
	root, depth, err := rootOf(ctx, d, parent)
	if err != nil {
		return err
	}
	if depth+1 > MaxSubSessionDepth {
		return &ValidationError{Msg: fmt.Sprintf("%s: sub-sessions nest at most %d deep; #%d is %d deep under #%d.",
			CodeLimit, MaxSubSessionDepth, parent, depth, root)}
	}
	runs, err := deps.runs(ctx)
	if err != nil {
		return err
	}
	n, err := liveUnder(ctx, d, runs, root)
	if err != nil {
		return err
	}
	if n >= MaxLiveSubSessions {
		return &ValidationError{Msg: fmt.Sprintf("%s: %d sub-sessions are live under #%d", CodeLimit, n, root)}
	}
	return nil
}

// rootOf walks session id's parent links up to its root and answers the
// root and how many links it took.
func rootOf(ctx context.Context, d *db.DB, id int64) (root int64, depth int, err error) {
	root = id
	for depth < maxChain {
		var parent sql.NullInt64
		err := d.QueryRowContext(ctx, `SELECT parent_session_id FROM terminal_sessions WHERE id = ? AND `+db.NotDeletingSQL, root).Scan(&parent)
		if errors.Is(err, sql.ErrNoRows) {
			break
		}
		if err != nil {
			return 0, 0, fmt.Errorf("reading session %d's parent: %w", root, err)
		}
		if !parent.Valid {
			break
		}
		root = parent.Int64
		depth++
	}
	return root, depth, nil
}

// liveUnder counts the live sessions below root at every depth: running in
// the host (runs) or still starting.
func liveUnder(ctx context.Context, d *db.DB, runs map[int64]bool, root int64) (int, error) {
	rows, err := d.QueryContext(ctx, `WITH RECURSIVE tree(id, depth) AS (
			SELECT id, 0 FROM terminal_sessions WHERE id = ?
			UNION ALL
			SELECT t.id, tree.depth + 1 FROM terminal_sessions t JOIN tree ON t.parent_session_id = tree.id
			WHERE tree.depth < ?)
		SELECT s.id, `+startingSQL+` FROM tree JOIN terminal_sessions s ON s.id = tree.id
		WHERE tree.depth > 0 AND s.`+db.NotDeletingSQL, root, maxChain)
	if err != nil {
		return 0, fmt.Errorf("reading the sub-sessions of #%d: %w", root, err)
	}
	defer rows.Close()
	n := 0
	for rows.Next() {
		var id int64
		var starting bool
		if err := rows.Scan(&id, &starting); err != nil {
			return 0, fmt.Errorf("reading the sub-sessions of #%d: %w", root, err)
		}
		if runs[id] || starting {
			n++
		}
	}
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("reading the sub-sessions of #%d: %w", root, err)
	}
	return n, nil
}

// sessionView is one list_sessions row: state is the agent's reported state
// (working, waiting, approval) or starting before its first report; live
// is false for a session still starting (not in the host yet).
type sessionView struct {
	SessionID       int64  `json:"session_id"`
	Title           string `json:"title"`
	Folder          string `json:"folder"`
	State           string `json:"state"`
	ParentSessionID *int64 `json:"parent_session_id"`
	Live            bool   `json:"live"`
}

// NewListSessions lists the bound workbench's live agent sessions (spec
// 2026-11-18 §5): the peers send_to_session can reach.
func NewListSessions(deps SessionDeps) *Tool {
	return &Tool{
		Name: "list_sessions",
		Description: "List the live agent sessions of this workbench (running, or starting) with their id, title, bench " +
			"folder, state (working, waiting, approval or starting) and parent session (null for a top-level session). " +
			"Use the ids with send_to_session.",
		InputSchema: mustSchema[emptyArgs]("list_sessions"),
		Access:      AccessRead,
		Surfaces:    workbenchSurfaces,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			p, err := workbenchOf(ctx, d, call.Binding)
			if err != nil {
				return nil, err
			}
			runs, err := deps.runs(ctx)
			if err != nil {
				return nil, err
			}
			return liveSessions(ctx, d, p.ID, runs)
		},
	}
}

// liveSessions is workbench wb's agent sessions running in the host (runs)
// or still starting, by id; never nil.
func liveSessions(ctx context.Context, d *db.DB, wb int64, runs map[int64]bool) ([]sessionView, error) {
	names, home, err := folderNames(ctx, d, wb)
	if err != nil {
		return nil, err
	}
	rows, err := d.QueryContext(ctx, `SELECT id, title, workbench_folder_id, COALESCE(agent_state, ''), parent_session_id, `+
		startingSQL+` FROM terminal_sessions
		WHERE project_id = ? AND kind IN ('claude', 'codex') AND `+db.NotDeletingSQL+` ORDER BY id`, wb)
	if err != nil {
		return nil, fmt.Errorf("listing the sessions of workbench %d: %w", wb, err)
	}
	defer rows.Close()
	out := []sessionView{}
	for rows.Next() {
		var v sessionView
		var folder, parent sql.NullInt64
		var starting bool
		if err := rows.Scan(&v.SessionID, &v.Title, &folder, &v.State, &parent, &starting); err != nil {
			return nil, fmt.Errorf("listing the sessions of workbench %d: %w", wb, err)
		}
		v.Live = runs[v.SessionID]
		if !v.Live && !starting {
			continue
		}
		if v.State == "" {
			v.State = "starting"
		}
		v.Folder = home
		if folder.Valid {
			v.Folder = names[folder.Int64]
		}
		if parent.Valid {
			v.ParentSessionID = &parent.Int64
		}
		out = append(out, v)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing the sessions of workbench %d: %w", wb, err)
	}
	return out, nil
}

// folderNames is every folder of workbench wb (removed ones included) by id
// to its stored name, and the home folder's name.
func folderNames(ctx context.Context, d *db.DB, wb int64) (map[int64]string, string, error) {
	all, err := d.WorkbenchFolders(ctx, wb, true)
	if err != nil {
		return nil, "", err //nolint:wrapcheck // db's message names the workbench
	}
	names := make(map[int64]string, len(all))
	for _, f := range all {
		names[f.ID] = f.Name
	}
	home, err := d.HomeFolder(ctx, wb)
	if err != nil {
		return nil, "", err //nolint:wrapcheck // db's message names the workbench
	}
	return names, home.Name, nil
}
