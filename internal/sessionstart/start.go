package sessionstart

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"

	"golang.org/x/text/unicode/norm"

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/providers"
	"watchtower/internal/sessionhost"
	"watchtower/internal/workbenchgit"
)

// Start states (StartResult.State and `workbench session start --json`):
// the row exists and its placement and launch still run (instant start,
// #942), the launch went to session-host, or it did not run (the reason is
// in the row's agent_error).
const (
	StateStarting = "starting"
	StateRunning  = "running"
	StateFailed   = "failed"
)

// PlanFirstSuffix follows a new session's first prompt when the phone asks
// for a plan first (TerminalLaunch.planFirstSuffix).
const PlanFirstSuffix = "Plan first: put the plan on the board, then ask me with ask_owner before you change any code."

// Launch size of a detached session: the Desktop's pane resizes it when it
// attaches.
const (
	launchCols = 80
	launchRows = 24
)

// ErrAlreadyLaunched refuses a Finish of a row the host already runs.
var ErrAlreadyLaunched = errors.New("the session is already running")

// DefaultLaunchWatch is how long the hub's port watches a new launch for an
// exit 127 (the login shell found no agent binary) before it answers the
// phone (SessionStartStopHandlers.defaultLaunchWatch); launchWatchStep is
// its poll.
const (
	DefaultLaunchWatch = 3 * time.Second
	launchWatchStep    = 100 * time.Millisecond
)

// Deps is what a start or stop runs against. DB is the workspace database,
// DBPath its file (the session-host scope is derived from it), Socket the
// host socket ("" = sessionhost.DefaultSocket, which honours
// WATCHTOWER_SESSION_HOST_SOCKET) and CLIPath the watchtower binary
// sessionhost.Ensure starts a host with ("" = this executable). Clock nil is
// time.Now.
type Deps struct {
	DB                      *db.DB
	Socket, CLIPath, DBPath string
	Clock                   func() time.Time

	// Shell is the owner's login shell ("" = $SHELL, else FallbackShell).
	Shell string
	// DefaultAgent is `workbench.default_agent` for a start that names no
	// agent (nil = Claude).
	DefaultAgent func() agentkind.Kind
	// CodexArgs is `workbench launch-args --agent codex` for the workbench;
	// devpack.ErrCodexNotFound when there is no codex binary. nil = Codex
	// cannot be launched (not found).
	CodexArgs func(ctx context.Context, workbenchID int64) (devpack.LaunchArgs, error)
	// Integrate installs the workbench integration in a worktree a start
	// just made (`workbench worktree create`'s install: the skill, the
	// hooks and its own `claude mcp add`); nil installs nothing.
	Integrate func(ctx context.Context, workbenchID int64, folder string, agent agentkind.Kind) error
	// SkillKnowsGroups reports whether the folder's agent skill knows the
	// group work-on prompt (`integrate status`); nil = it does (the shipped
	// skill does, as the Desktop assumes while the status is unknown).
	SkillKnowsGroups func(ctx context.Context, workbenchID int64, agent agentkind.Kind) bool
	// LaunchWatch, when positive, watches a launch that long: an exit 127
	// is *handlers.AgentNotFoundError (the phone's claude_not_found /
	// codex_not_found), any other exit the session's own end.
	LaunchWatch time.Duration

	// host leases a session-host client (the port's own; nil = dial one
	// per call).
	host func(ctx context.Context) (*sessionhost.Client, func(error), error)
}

func (d Deps) now() time.Time {
	if d.Clock != nil {
		return d.Clock()
	}
	return time.Now()
}

// socket is d.Socket, else sessionhost.DefaultSocket (an unusable Linux
// socket folder is its ErrRunDirUnusable error).
func (d Deps) socket() (string, error) {
	if d.Socket != "" {
		return d.Socket, nil
	}
	return sessionhost.DefaultSocket()
}

func (d Deps) scope() string { return sessionhost.Scope(d.DBPath) }

// lease is a client for one call: the port's, or a new connection (the host
// started first when none answers) closed on release.
func (d Deps) lease(ctx context.Context) (*sessionhost.Client, func(error), error) {
	if d.host != nil {
		return d.host(ctx)
	}
	socket, err := d.socket()
	if err != nil {
		return nil, nil, err
	}
	c, err := dialHost(ctx, socket, d.CLIPath)
	if err != nil {
		return nil, nil, err
	}
	return c, func(error) { _ = c.Close() }, nil
}

// dialHost makes sure a host answers on socket (starting `exe session-host`
// when none does) and connects to it.
func dialHost(ctx context.Context, socket, exe string) (*sessionhost.Client, error) {
	if exe == "" {
		self, err := os.Executable()
		if err != nil {
			return nil, fmt.Errorf("locating the watchtower binary: %w", err)
		}
		exe = self
	}
	if err := sessionhost.Ensure(ctx, socket, exe); err != nil {
		return nil, fmt.Errorf("the session host is not running: %w", err)
	}
	c, err := sessionhost.Dial(ctx, socket)
	if err != nil {
		return nil, fmt.Errorf("the session host is not running: %w", err)
	}
	return c, nil
}

// workbenchRow is what a start reads of its workbench.
type workbenchRow struct {
	id     int64
	folder string
	setup  string
}

func loadWorkbench(ctx context.Context, q *db.DB, id int64) (workbenchRow, error) {
	w := workbenchRow{id: id}
	err := q.QueryRowContext(ctx, `SELECT folder_path, worktree_setup FROM projects WHERE id = ?`, id).Scan(&w.folder, &w.setup)
	if errors.Is(err, sql.ErrNoRows) {
		return w, fmt.Errorf("workbench %d: %w", id, db.ErrWorkbenchNotFound)
	}
	if err != nil {
		return w, fmt.Errorf("reading workbench %d: %w", id, err)
	}
	return w, nil
}

// targetRow is a start's target: its text and whether it is a group (it has
// sub-targets on its workbench).
type targetRow struct {
	id      int64
	text    string
	isGroup bool
}

// loadTarget reads a target on workbench wb's board; handlers.ErrStartNotOnBoard
// when it is gone or on another board (or none).
func loadTarget(ctx context.Context, q *db.DB, id, wb int64) (targetRow, error) {
	t := targetRow{id: id}
	var project sql.NullInt64
	err := q.QueryRowContext(ctx, `SELECT text, project_id FROM targets WHERE id = ?`, id).Scan(&t.text, &project)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && (!project.Valid || project.Int64 != wb)) {
		return t, handlers.ErrStartNotOnBoard
	}
	if err != nil {
		return t, fmt.Errorf("reading target %d: %w", id, err)
	}
	err = q.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM targets WHERE parent_id = ? AND project_id = ?)`, id, wb).
		Scan(&t.isGroup)
	if err != nil {
		return t, fmt.Errorf("reading target %d: %w", id, err)
	}
	return t, nil
}

// One process's starts in flight: the targets being started (a second start
// of one is refused, ErrStartInProgress), the rows still being placed and
// launched (they count as agents in the folder for a later start, by id), and
// one placement turn per workbench.
var inFlight = struct {
	sync.Mutex
	targets map[int64]bool
	rows    map[int64]startingRow
	turns   map[int64]*sync.Mutex
}{targets: map[int64]bool{}, rows: map[int64]startingRow{}, turns: map[int64]*sync.Mutex{}}

type startingRow struct {
	workbench      int64
	folder, branch string
}

func beginTarget(id int64) bool {
	inFlight.Lock()
	defer inFlight.Unlock()
	if inFlight.targets[id] {
		return false
	}
	inFlight.targets[id] = true
	return true
}

func endTarget(id int64) {
	inFlight.Lock()
	defer inFlight.Unlock()
	delete(inFlight.targets, id)
}

func setStarting(id int64, r *startingRow) {
	inFlight.Lock()
	defer inFlight.Unlock()
	if r == nil {
		delete(inFlight.rows, id)
		return
	}
	inFlight.rows[id] = *r
}

// startingBefore lists the workbench's rows other starts of this process are
// still placing or launching, with an id below id: a start begun later never
// pushes an earlier one into a worktree.
func startingBefore(wb, id int64) map[int64]startingRow {
	inFlight.Lock()
	defer inFlight.Unlock()
	out := map[int64]startingRow{}
	for rid, r := range inFlight.rows {
		if r.workbench == wb && rid < id {
			out[rid] = r
		}
	}
	return out
}

// placementTurn runs fn after every earlier start's placement of the
// workbench in this process ended (WorkbenchesViewModel.inPlacementTurn).
func placementTurn(wb int64, fn func()) {
	inFlight.Lock()
	m := inFlight.turns[wb]
	if m == nil {
		m = &sync.Mutex{}
		inFlight.turns[wb] = m
	}
	inFlight.Unlock()
	m.Lock()
	defer m.Unlock()
	fn()
}

// Start starts an agent session on a workbench, as the Desktop's New Session
// and Work on It do (spec 2026-10-31 §11):
//
//  1. the row first, in **Starting…**, in the workbench folder;
//  2. its place (Place, Prepare): its own worktree when a live agent already
//     works in the folder (or as r.Place asks), with the .worktreeinclude
//     paths, the workbench's setup command before the agent's first start,
//     and the integration (`claude mcp add`) installed in every new worktree;
//  3. the launch argv (Launch, with `launch-args` for Codex);
//  4. the session-host Launch under the workspace's scope and the agent;
//  5. the launch checked (launchCheck): a refused launch, an unreachable
//     host or a failed placement is an error, never a started session; with
//     d.LaunchWatch an exit 127 is *handlers.AgentNotFoundError.
//
// Begin is steps 1 alone (the CLI's instant start, #942) and Finish steps
// 2–5 for its row, in another process.
//
// r.Target: the target's session is reopened (resumed) when r.OpenExisting
// and it has one; a new one is named after the target and gets r.Brief or the
// work-on prompt. No target: a new session with r.Brief. r.PlanFirst follows
// the prompt with PlanFirstSuffix. r.Agent "" is d.DefaultAgent; r.Place ""
// is auto.
//
// A launch the host refused leaves the row out of Starting… with the reason
// in agent_error; a worktree made for it stays (nothing is removed on a
// failure; `workbench cleanup` lists it). Refusals before any row:
// handlers.ErrStartNotOnBoard, handlers.ErrStartInProgress,
// *handlers.AgentNotFoundError (Codex without a codex binary), a policy
// refusal of the agent, a bad agent or place.
func Start(ctx context.Context, d Deps, r handlers.StartRequest) (handlers.StartResult, error) {
	st, done, res, err := begin(ctx, d, r)
	if st == nil {
		return res, err
	}
	defer done()
	if err := st.finish(ctx); err != nil {
		return handlers.StartResult{SessionID: st.id, State: StateFailed}, err
	}
	return handlers.StartResult{SessionID: st.id, State: StateRunning}, nil
}

// Begin writes a new session's row (Starting…, in the workbench folder) and
// answers {id, starting} at once, with Start's refusals; Finish places and
// launches it. An OpenExisting start that finds the target's session is
// answered as Start answers it.
func Begin(ctx context.Context, d Deps, r handlers.StartRequest) (handlers.StartResult, error) {
	st, done, res, err := begin(ctx, d, r)
	if st == nil {
		return res, err
	}
	done()
	return handlers.StartResult{SessionID: st.id, State: StateStarting}, nil
}

// Finish places and launches a row Begin wrote, rebuilt from the row:
// its agent, target and Claude session id; brief (else the target's
// work-on prompt) and planFirst make the first prompt. A row the host
// already runs is refused. Failures are recorded on the row as Start's are.
func Finish(ctx context.Context, d Deps, sessionID int64, place, brief string, planFirst bool) error {
	choice, err := parseChoice(place)
	if err != nil {
		return err
	}
	var wbID, targetID sql.NullInt64
	var kind, claudeID string
	err = d.DB.QueryRowContext(ctx, `SELECT project_id, kind, target_id, COALESCE(claude_session_id, '')
		FROM terminal_sessions WHERE id = ?`, sessionID).Scan(&wbID, &kind, &targetID, &claudeID)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("terminal session %d: %w", sessionID, db.ErrTerminalSessionNotFound)
	}
	if err != nil {
		return fmt.Errorf("reading terminal session %d: %w", sessionID, err)
	}
	agent, ok := agentkind.Parse(kind)
	if !wbID.Valid || !ok {
		return fmt.Errorf("terminal session %d is not a workbench agent session", sessionID)
	}
	st := &newStart{d: d, agent: agent, choice: choice, claudeID: claudeID, id: sessionID}
	if st.wb, err = loadWorkbench(ctx, d.DB, wbID.Int64); err != nil {
		return err
	}
	if targetID.Valid {
		if t, err := loadTarget(ctx, d.DB, targetID.Int64, st.wb.id); err == nil {
			st.target = &t
		}
	}
	if st.codex, err = codexArgs(ctx, d, agent, st.wb.id); err != nil {
		st.markFailed(ctx, notFoundReason(agent))
		return err
	}
	st.prompt = st.firstPrompt(ctx, brief, planFirst)
	setStarting(sessionID, &startingRow{workbench: st.wb.id, folder: st.wb.folder})
	defer setStarting(sessionID, nil)
	return st.finish(ctx)
}

func parseChoice(place string) (Choice, error) {
	switch c := Choice(place); c {
	case "":
		return ChoiceAuto, nil
	case ChoiceAuto, ChoiceFolder, ChoiceWorktree:
		return c, nil
	}
	return "", fmt.Errorf("place must be folder, worktree or auto, got %q", place)
}

// begin is Start up to the row: nil st when it answered without one (a
// refusal, or an existing session reopened). done releases the target and
// the in-flight row.
func begin(ctx context.Context, d Deps, r handlers.StartRequest) (st *newStart, done func(), res handlers.StartResult, err error) {
	choice, err := parseChoice(r.Place)
	if err != nil {
		return nil, nil, res, err
	}
	agent, err := startAgent(d, r.Agent)
	if err != nil {
		return nil, nil, res, err
	}
	wb, err := loadWorkbench(ctx, d.DB, r.Workbench)
	if err != nil {
		return nil, nil, res, err
	}
	var target *targetRow
	if r.Target != nil {
		t, err := loadTarget(ctx, d.DB, *r.Target, wb.id)
		if err != nil {
			return nil, nil, res, err
		}
		if !beginTarget(t.id) {
			return nil, nil, res, handlers.ErrStartInProgress
		}
		target = &t
	}
	release := func() {
		if target != nil {
			endTarget(target.id)
		}
	}
	if target != nil && r.OpenExisting {
		existing, found, err := latestTargetSession(ctx, d.DB, target.id, wb.id, r.Agent)
		if err != nil {
			release()
			return nil, nil, res, err
		}
		if found {
			defer release()
			res, err = reopen(ctx, d, existing)
			return nil, nil, res, err
		}
	}
	st = &newStart{d: d, wb: wb, target: target, agent: agent, choice: choice}
	if st.codex, err = codexArgs(ctx, d, agent, wb.id); err != nil {
		release()
		return nil, nil, res, err
	}
	st.prompt = st.firstPrompt(ctx, r.Brief, r.PlanFirst)
	if err := st.insert(ctx); err != nil {
		release()
		return nil, nil, res, err
	}
	return st, func() {
		setStarting(st.id, nil)
		release()
	}, res, nil
}

// startAgent is the agent a start runs, refused when unknown or when the
// organization's policy forbids it (#608).
func startAgent(d Deps, name string) (agentkind.Kind, error) {
	agent := agentkind.Claude
	if name != "" {
		k, ok := agentkind.Parse(name)
		if !ok {
			return "", fmt.Errorf("agent must be claude or codex, got %q", name)
		}
		agent = k
	} else if d.DefaultAgent != nil {
		if k, ok := agentkind.Parse(string(d.DefaultAgent())); ok {
			agent = k
		}
	}
	if err := providers.Allowed(string(agent)); err != nil {
		return "", err //nolint:wrapcheck // the policy's own sentence is the message
	}
	return agent, nil
}

// codexArgs is `launch-args` for a Codex launch (nil for Claude); a missing
// codex binary is *handlers.AgentNotFoundError.
func codexArgs(ctx context.Context, d Deps, agent agentkind.Kind, wb int64) (*devpack.LaunchArgs, error) {
	if agent != agentkind.Codex {
		return nil, nil
	}
	if d.CodexArgs == nil {
		return nil, &handlers.AgentNotFoundError{Agent: string(agentkind.Codex)}
	}
	la, err := d.CodexArgs(ctx, wb)
	if errors.Is(err, devpack.ErrCodexNotFound) {
		return nil, &handlers.AgentNotFoundError{Agent: string(agentkind.Codex)}
	}
	if err != nil {
		return nil, fmt.Errorf("codex launch arguments: %w", err)
	}
	return &la, nil
}

// newStart is one new session being started.
type newStart struct {
	d        Deps
	wb       workbenchRow
	target   *targetRow
	agent    agentkind.Kind
	choice   Choice
	codex    *devpack.LaunchArgs
	prompt   string
	claudeID string
	id       int64
}

// firstPrompt is the brief, else the work-on prompt (the group wording for a
// group whose skill knows it), followed by PlanFirstSuffix when asked.
func (s *newStart) firstPrompt(ctx context.Context, brief string, planFirst bool) string {
	p := strings.TrimSpace(brief)
	if p == "" && s.target != nil {
		knows := s.d.SkillKnowsGroups == nil || s.d.SkillKnowsGroups(ctx, s.wb.id, s.agent)
		p = WorkOnPrompt(s.target.id, s.target.isGroup, knows)
	}
	if planFirst {
		p = strings.TrimSpace(p + " " + PlanFirstSuffix)
	}
	return p
}

// insert writes the row in the workbench folder (Starting…).
func (s *newStart) insert(ctx context.Context) error {
	n := db.NewTerminalSession{WorkbenchID: s.wb.id, Kind: string(s.agent), FolderPath: s.wb.folder,
		Title: ProvisionalTitle(s.d.now())}
	if s.target != nil {
		n.TargetID = s.target.id
		n.Title = strings.TrimSpace(s.target.text)
		if n.Title == "" {
			n.Title = "Target #" + strconv.FormatInt(s.target.id, 10)
		}
	}
	if s.agent == agentkind.Claude {
		s.claudeID = NewSessionID()
		n.ClaudeSessionID = s.claudeID
	}
	id, err := s.d.DB.CreateTerminalSession(ctx, n)
	if err != nil {
		return err //nolint:wrapcheck // CreateTerminalSession wraps
	}
	s.id = id
	setStarting(id, &startingRow{workbench: s.wb.id, folder: s.wb.folder})
	return nil
}

// finish places the row and launches it. A failure after the row exists
// leaves it out of Starting… with the reason in agent_error.
func (s *newStart) finish(ctx context.Context) error {
	c, done, err := s.d.lease(ctx)
	if err != nil {
		s.markFailed(ctx, "the session host is not running")
		return err
	}
	var hostErr error
	defer func() { done(hostErr) }()
	list, err := c.List(ctx)
	if err != nil {
		s.markFailed(ctx, "the session host could not be read")
		return fmt.Errorf("listing the session host: %w", err)
	}
	if info, ok := findRun(list, s.d.scope(), s.id); ok && !info.Exited {
		return ErrAlreadyLaunched
	}
	dir, placed, err := s.place(ctx, c)
	if err != nil {
		hostErr = err
		return err
	}
	setup := ""
	if placed && strings.TrimSpace(s.wb.setup) != "" {
		setup = s.wb.setup
	}
	// Deleted while its place was decided: it never launches.
	var one int
	if err := s.d.DB.QueryRowContext(ctx, `SELECT 1 FROM terminal_sessions WHERE id = ?`, s.id).Scan(&one); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("Session #%d was deleted before it started.", s.id) //nolint:staticcheck // Swift's sentence, verbatim
		}
		return fmt.Errorf("reading session %d: %w", s.id, err)
	}
	m := Mode{Agent: string(s.agent), SessionID: s.claudeID}
	if s.prompt != "" {
		p := s.prompt
		m.Prompt = &p
	}
	run, err := launch(ctx, s.d, c, s.id, dir, m, s.codex, setup)
	if err != nil {
		return err
	}
	return watchLaunch(ctx, s.d, c, s.id, run, s.agent)
}

// watchLaunch is SessionStartStopHandlers.exitedNotFound: for d.LaunchWatch
// the launch run is watched while it runs; an exit 127 within it is the
// agent not found (recorded on the row too), any other exit the session's
// own end.
func watchLaunch(ctx context.Context, d Deps, c *sessionhost.Client, row int64, run string, agent agentkind.Kind) error {
	if d.LaunchWatch <= 0 {
		return nil
	}
	deadline := time.Now().Add(d.LaunchWatch)
	for {
		list, err := c.List(ctx)
		if err != nil {
			return nil //nolint:nilerr // the launch ran; a failed watch read is no refusal
		}
		var info *sessionhost.SessionInfo
		for i := range list {
			if list[i].Row == row && list[i].Run == run {
				info = &list[i]
			}
		}
		if info == nil {
			return nil
		}
		if info.Exited {
			if info.Code != nil && *info.Code == 127 {
				_ = d.DB.SetTerminalSessionLaunchError(context.WithoutCancel(ctx), row, notFoundReason(agent), d.now())
				return &handlers.AgentNotFoundError{Agent: string(agent)}
			}
			return nil
		}
		if !time.Now().Before(deadline) {
			return nil
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(launchWatchStep):
		}
	}
}

// notFoundReason is agent_error's reason for a missing agent binary.
func notFoundReason(agent agentkind.Kind) string { return string(agent) + " was not found" }

// place moves the row where Place decides, in the workbench's placement
// turn: dir is where it starts, placed whether it went into a worktree made
// for it. A row that could not be moved into its new worktree is deleted (it
// never ran) and the worktree stays on disk.
func (s *newStart) place(ctx context.Context, c *sessionhost.Client) (dir string, placed bool, err error) {
	placementTurn(s.wb.id, func() {
		occupied, working, oerr := s.occupied(ctx, c)
		if oerr != nil {
			err = oerr
			s.markFailed(ctx, "the session host could not be read")
			return
		}
		o := workbenchgit.Options{Folder: s.wb.folder}
		var st *workbenchgit.Status
		if WantsWorktree(occupied, s.choice) {
			read := workbenchgit.ReadStatus(ctx, o)
			st = &read
		}
		var targetID *int64
		var targetText string
		if s.target != nil {
			targetID, targetText = &s.target.id, s.target.text
		}
		prep := Prepare(ctx, o, Place(occupied, s.choice, st), Slug(targetID, targetText, working+1), "",
			s.d.DB.HeldWorktreeBranches)
		dir = prep.Dir
		if prep.Worktree == nil {
			return
		}
		if s.d.Integrate != nil {
			// The session runs without it (no hooks or board tools); logged
			// by id and class only (FILES-01).
			if ierr := s.d.Integrate(ctx, s.wb.id, prep.Dir, s.agent); ierr != nil {
				log.Printf("sessionstart: session %d: worktree integration failed (%s)", s.id, errClass(ierr))
			}
		}
		if perr := s.d.DB.PlaceTerminalSession(ctx, s.id, prep.Dir, prep.Worktree.Branch, prep.Worktree.Base); perr != nil {
			_, _ = s.d.DB.ExecContext(context.WithoutCancel(ctx), `DELETE FROM terminal_sessions WHERE id = ?`, s.id)
			err = fmt.Errorf("could not move session %d into its worktree (the worktree was kept): %w", s.id, perr)
			return
		}
		placed = true
		setStarting(s.id, &startingRow{workbench: s.wb.id, folder: prep.Dir, branch: prep.Worktree.Branch})
	})
	return dir, placed, err
}

// agentRow is a workbench agent row as the folder check reads it.
type agentRow struct {
	id                  int64
	folder, branch, cwd string
	cwdAt               string
}

// occupied reports whether a live agent already works in the workbench
// folder (SessionStartPlacement.occupies over the live agent rows and the
// earlier starts still launching) and how many such rows work on the
// workbench at all (the worktree's session number is one more).
func (s *newStart) occupied(ctx context.Context, c *sessionhost.Client) (occupied bool, working int, err error) {
	list, err := c.List(ctx)
	if err != nil {
		return false, 0, fmt.Errorf("listing the session host: %w", err)
	}
	scope := s.d.scope()
	live := map[int64]sessionhost.SessionInfo{}
	for _, info := range list {
		if info.Scope == scope && !info.Exited {
			live[info.Row] = info
		}
	}
	rows, err := s.d.DB.QueryContext(ctx, `SELECT id, folder_path, COALESCE(worktree_branch, ''),
		COALESCE(agent_cwd, ''), COALESCE(agent_cwd_at, '')
		FROM terminal_sessions WHERE project_id = ? AND kind IN ('claude', 'codex') AND id <> ?`, s.wb.id, s.id)
	if err != nil {
		return false, 0, fmt.Errorf("reading the workbench's sessions: %w", err)
	}
	defer rows.Close()
	starting := startingBefore(s.wb.id, s.id)
	for rows.Next() {
		var r agentRow
		if err := rows.Scan(&r.id, &r.folder, &r.branch, &r.cwd, &r.cwdAt); err != nil {
			return false, 0, fmt.Errorf("reading the workbench's sessions: %w", err)
		}
		info, isLive := live[r.id]
		if st, ok := starting[r.id]; ok && !isLive {
			working++
			occupied = occupied || occupies(st.branch, st.folder, "", s.wb.folder)
			continue
		}
		if !isLive {
			continue
		}
		working++
		occupied = occupied || occupies(r.branch, r.folder, trustedCwd(r, info), s.wb.folder)
	}
	if err := rows.Err(); err != nil {
		return false, 0, fmt.Errorf("reading the workbench's sessions: %w", err)
	}
	return occupied, working, nil
}

// trustedCwd is the row's reported working directory when it was reported
// in the live run (stamped at or after the run's start), else "" (D10).
func trustedCwd(r agentRow, info sessionhost.SessionInfo) string {
	if r.cwd == "" || info.StartedAtMs == 0 {
		return ""
	}
	at, ok := db.ParseAgentStateStamp(r.cwdAt)
	if !ok || at.Before(time.UnixMilli(info.StartedAtMs)) {
		return ""
	}
	return r.cwd
}

// occupies is SessionStartPlacement.occupies without git: a trusted cwd
// outside every session worktree is the folder; with none, a row not placed
// in a worktree whose folder is the workbench folder is.
func occupies(branch, folder, cwd, workbenchFolder string) bool {
	if cwd != "" {
		return WorktreeTop(cwd) == ""
	}
	return branch == "" && filepath.Clean(folder) == filepath.Clean(workbenchFolder)
}

func (s *newStart) markFailed(ctx context.Context, reason string) {
	_ = s.d.DB.SetTerminalSessionLaunchError(context.WithoutCancel(ctx), s.id, reason, s.d.now())
}

// launch builds the argv (Launch) and hands it to session-host. A refused
// launch is recorded on the row (agent_error) and returned.
func launch(ctx context.Context, d Deps, c *sessionhost.Client, row int64, dir string, m Mode,
	codex *devpack.LaunchArgs, setup string,
) (run string, err error) {
	shell := d.Shell
	if shell == "" {
		shell = os.Getenv("SHELL")
	}
	spec, err := Launch(m, row, dir, shell, codex, setup)
	if err != nil {
		_ = d.DB.SetTerminalSessionLaunchError(context.WithoutCancel(ctx), row, "the launch could not be built", d.now())
		return "", err
	}
	run = NewSessionID()
	_, err = c.Launch(ctx, sessionhost.LaunchReq{
		Row: row, Run: run, Executable: spec.Executable, Args: spec.Args,
		Env: append(baseEnv(spec.Executable), spec.Env...), Cwd: spec.Dir, Cols: launchCols, Rows: launchRows,
		Scope: d.scope(), Agent: m.Agent,
	})
	if err != nil {
		_ = d.DB.SetTerminalSessionLaunchError(context.WithoutCancel(ctx), row, launchFailure(err), d.now())
		return "", fmt.Errorf("session %d did not launch: %w", row, err)
	}
	return run, nil
}

// errClass is an error's class for a log line: its type, never its text.
func errClass(err error) string {
	var he *sessionhost.HostError
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.As(err, &he):
		return "host"
	}
	return fmt.Sprintf("%T", err)
}

// launchFailure is agent_error's reason for a refused launch: the host's own
// message when it answered one.
func launchFailure(err error) string {
	var he *sessionhost.HostError
	if errors.As(err, &he) && he.Message != "" {
		return "launch refused: " + he.Message
	}
	return "the session host did not launch the session"
}

// baseEnv is a hosted launch's environment before its own entries, as the
// Desktop's processEnvironment gives it: SwiftTerm's terminal basics, the
// owner's identity and home, then SHELL.
func baseEnv(shell string) []string {
	env := []string{"TERM=xterm-256color", "COLORTERM=truecolor", "LANG=en_US.UTF-8"}
	for _, name := range []string{"LOGNAME", "USER", "DISPLAY", "LC_TYPE", "HOME"} {
		if v, ok := os.LookupEnv(name); ok {
			env = append(env, name+"="+v)
		}
	}
	return append(env, "SHELL="+shell)
}

// existingRow is a target's session as reopen reads it.
type existingRow struct {
	id, workbench  int64
	kind, folder   string
	agentSessionID string
}

// latestTargetSession is the target's most recently active session on the
// workbench (TerminalSessionPolicy.sessionForTarget), of agent when one is
// named.
func latestTargetSession(ctx context.Context, q *db.DB, target, wb int64, agent string) (existingRow, bool, error) {
	r := existingRow{workbench: wb}
	err := q.QueryRowContext(ctx, `SELECT id, kind, folder_path, COALESCE(claude_session_id, '')
		FROM terminal_sessions WHERE target_id = ? AND project_id = ? AND kind IN ('claude', 'codex')
		  AND (? = '' OR kind = ?)
		ORDER BY last_active_at DESC, id DESC LIMIT 1`, target, wb, agent, agent).
		Scan(&r.id, &r.kind, &r.folder, &r.agentSessionID)
	if errors.Is(err, sql.ErrNoRows) {
		return r, false, nil
	}
	if err != nil {
		return r, false, fmt.Errorf("reading target %d's sessions: %w", target, err)
	}
	return r, true, nil
}

// reopen answers a target's existing session: running in the host already,
// it is answered as is; else it resumes (a Codex row with no id of its own
// yet starts again with no prompt).
func reopen(ctx context.Context, d Deps, r existingRow) (handlers.StartResult, error) {
	agent := agentkind.Kind(r.kind)
	if err := providers.Allowed(r.kind); err != nil {
		return handlers.StartResult{}, err //nolint:wrapcheck // the policy's own sentence is the message
	}
	codex, err := codexArgs(ctx, d, agent, r.workbench)
	if err != nil {
		return handlers.StartResult{}, err
	}
	c, done, err := d.lease(ctx)
	if err != nil {
		return handlers.StartResult{}, err
	}
	var hostErr error
	defer func() { done(hostErr) }()
	list, err := c.List(ctx)
	if err != nil {
		hostErr = err
		return handlers.StartResult{}, fmt.Errorf("listing the session host: %w", err)
	}
	if info, ok := findRun(list, d.scope(), r.id); ok && !info.Exited {
		return handlers.StartResult{SessionID: r.id, State: StateRunning}, nil
	}
	if _, err := d.DB.ExecContext(ctx, `UPDATE terminal_sessions SET last_active_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ?`, r.id); err != nil {
		return handlers.StartResult{}, fmt.Errorf("opening session %d: %w", r.id, err)
	}
	m := Mode{Agent: r.kind, SessionID: r.agentSessionID, Resume: r.agentSessionID != ""}
	run, err := launch(ctx, d, c, r.id, r.folder, m, codex, "")
	if err == nil {
		err = watchLaunch(ctx, d, c, r.id, run, agent)
	}
	if err != nil {
		hostErr = err
		return handlers.StartResult{SessionID: r.id, State: StateFailed}, err
	}
	return handlers.StartResult{SessionID: r.id, State: StateRunning}, nil
}

// findRun is the row's run in this scope: the running one, else the latest
// launch that exited and was not forgotten.
func findRun(list []sessionhost.SessionInfo, scope string, row int64) (sessionhost.SessionInfo, bool) {
	var best sessionhost.SessionInfo
	found := false
	for _, info := range list {
		if info.Row != row || info.Scope != scope {
			continue
		}
		better := !found || (best.Exited && !info.Exited) || (best.Exited == info.Exited && info.Launch > best.Launch)
		if better {
			best, found = info, true
		}
	}
	return best, found
}

// WorkOnPrompt is TerminalLaunch.workOnPrompt: the group wording when the
// target has sub-targets and the skill knows that wording, else the target
// wording.
func WorkOnPrompt(targetID int64, isGroup, skillKnowsGroups bool) string {
	noun := "target"
	if isGroup && skillKnowsGroups {
		noun = "group"
	}
	return "Work on " + noun + " #" + strconv.FormatInt(targetID, 10) + " using the " + devpack.WorkbenchSkillName + " skill."
}

// ProvisionalTitle is TerminalSessionNaming.provisional: "New session ·
// HH:MM" in local time, until the AI title replaces it.
func ProvisionalTitle(now time.Time) string {
	return "New session · " + now.Local().Format("15:04")
}

// Slug is SessionStartPlacement.slug: `<target id>-<words>` (the target's
// text folded to lowercase ASCII words, each added while the whole stays
// within 40 characters) or `session-<n>` without a target.
func Slug(targetID *int64, targetText string, sessionNumber int) string {
	if targetID == nil {
		return "session-" + strconv.Itoa(sessionNumber)
	}
	var folded strings.Builder
	for _, r := range norm.NFD.String(targetText) {
		if !unicode.Is(unicode.Mn, r) {
			folded.WriteRune(unicode.ToLower(r))
		}
	}
	words := strings.FieldsFunc(folded.String(), func(r rune) bool {
		return r > unicode.MaxASCII || !(unicode.IsLetter(r) || unicode.IsDigit(r))
	})
	out := strconv.FormatInt(*targetID, 10)
	for _, w := range words {
		if len(out)+1+len(w) <= 40 {
			out += "-" + w
		}
	}
	return out
}

// WorktreeTop is SessionStartPlacement.worktreeTop: the ancestor of cwd
// whose parent's last two components are `.claude/worktrees`, "" outside
// one. A string walk: the path is not resolved.
func WorktreeTop(cwd string) string {
	var parts []string
	for _, p := range strings.Split(cwd, "/") {
		if p != "" {
			parts = append(parts, p)
		}
	}
	for i := 2; i < len(parts); i++ {
		if parts[i-2] == ".claude" && parts[i-1] == "worktrees" {
			top := strings.Join(parts[:i+1], "/")
			if strings.HasPrefix(cwd, "/") {
				top = "/" + top
			}
			return top
		}
	}
	return ""
}

// NewSessionID is a new lowercase canonical UUID (version 4): a new Claude
// session's id, and a launch's run token.
func NewSessionID() string {
	var b [16]byte
	_, _ = rand.Read(b[:]) // crypto/rand.Read never fails
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
