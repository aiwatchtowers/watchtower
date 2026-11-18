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
	"watchtower/internal/logredact"
	"watchtower/internal/providers"
	"watchtower/internal/sessionagent"
	"watchtower/internal/sessionhost"
	"watchtower/internal/workbenchfolders"
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
	// Hidden is the session ids waiting in the Desktop's Undo batch
	// (PROJ-17): an open_existing start never reopens one and starts a new
	// session instead. nil = none.
	Hidden func() map[int64]bool

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

// probeHost reaches the host (started first when none answers, as a lease
// does) and lets go: a start that must not leave a row behind when the host
// is down asks before it writes one.
func (d Deps) probeHost(ctx context.Context) error {
	_, done, err := d.lease(ctx)
	if err != nil {
		return err
	}
	done(nil)
	return nil
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

// Start refusals of a folder or a parent (spec 2026-11-18 §6.5, §7), as
// *workbenchfolders.Refusal ("<code>: <sentence>", D42) beside its own
// not_found and folder_removed.
const (
	CodeNotInstalled     = "not_installed"
	CodeFolderMissing    = "folder_missing"
	CodeNotSameWorkbench = "not_same_workbench"
)

// workbenchRow is what a start reads of its workbench and of the bench
// folder the session starts for: folder is that folder's path (the home
// folder's is projects.folder_path), home whether it is the home folder.
type workbenchRow struct {
	id     int64
	setup  string
	folder string
	bench  db.WorkbenchFolder
	home   bool
}

// loadWorkbench reads workbench id and its folder folderID (0 = the home
// folder): not_found when the folder is not one of the bench's,
// folder_removed when it left the bench.
func loadWorkbench(ctx context.Context, q *db.DB, id, folderID int64) (workbenchRow, error) {
	w := workbenchRow{id: id}
	var homePath string
	err := q.QueryRowContext(ctx, `SELECT folder_path, worktree_setup FROM projects WHERE id = ?`, id).Scan(&homePath, &w.setup)
	if errors.Is(err, sql.ErrNoRows) {
		return w, fmt.Errorf("workbench %d: %w", id, db.ErrWorkbenchNotFound)
	}
	if err != nil {
		return w, fmt.Errorf("reading workbench %d: %w", id, err)
	}
	ref := ""
	if folderID != 0 {
		ref = strconv.FormatInt(folderID, 10)
	}
	if w.bench, err = workbenchfolders.Resolve(ctx, q, id, ref); err != nil {
		// Finish names the folder by id: a legacy bench's fallback home
		// (removed, no live folder) still starts there, as Resolve("") does.
		var refused *workbenchfolders.Refusal
		if !errors.As(err, &refused) || refused.Code != workbenchfolders.CodeFolderRemoved || !fallbackHome(ctx, q, id, w.bench) {
			return w, err //nolint:wrapcheck // a Refusal or db's message naming the workbench
		}
	}
	w.folder, w.home = w.bench.FolderPath, strings.EqualFold(w.bench.FolderPath, homePath)
	if w.home {
		w.folder = homePath // the row's folder_path exactly as before
	}
	return w, nil
}

// fallbackHome reports whether f, removed, is still workbench wb's home
// (workbenchfolders.IsFallbackHome and db.HomeFolder's pick); a read error is
// logged by class and counts as no.
func fallbackHome(ctx context.Context, q *db.DB, wb int64, f db.WorkbenchFolder) bool {
	if f.WorkbenchID != wb {
		return false
	}
	fallback, err := workbenchfolders.IsFallbackHome(ctx, q, f)
	if err != nil {
		log.Printf("sessionstart: workbench %d: the fallback home could not be read (%s)", wb, errClass(err))
		return false
	}
	if !fallback {
		return false
	}
	home, err := q.HomeFolderID(ctx, wb)
	return err == nil && home == f.ID
}

// onDisk refuses a folder that is not on disk any more (folder_missing).
func (w workbenchRow) onDisk() error {
	if info, err := os.Stat(w.folder); err != nil || !info.IsDir() {
		return &workbenchfolders.Refusal{Code: CodeFolderMissing, Folder: &w.bench,
			Detail: fmt.Sprintf("%s is not at %s any more. Locate it or remove it from the bench.", w.bench.Name, w.folder)}
	}
	return nil
}

// checkFolder refuses a start in a folder that is not on disk
// (folder_missing) or, other than the home folder, has no Watchtower install
// for the workbench (not_installed): the home folder starts as it always did.
func (w workbenchRow) checkFolder() error {
	if err := w.onDisk(); err != nil {
		return err
	}
	if w.home {
		return nil
	}
	ok, err := devpack.HasCoreStateHooks(w.folder, w.id)
	if err != nil {
		return fmt.Errorf("reading Watchtower's install in %s: %w", w.bench.Name, err)
	}
	if !ok {
		return &workbenchfolders.Refusal{Code: CodeNotInstalled, Folder: &w.bench,
			Detail: "Install Watchtower in " + w.bench.Name + " first"}
	}
	return nil
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
	workbench, benchFolder int64
	folder, branch         string
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

// startingBefore lists the rows of the workbench folder benchFolder other
// starts of this process are still placing or launching, with an id below
// id: a start begun later never pushes an earlier one into a worktree.
func startingBefore(wb, benchFolder, id int64) map[int64]startingRow {
	inFlight.Lock()
	defer inFlight.Unlock()
	out := map[int64]startingRow{}
	for rid, r := range inFlight.rows {
		if r.workbench == wb && r.benchFolder == benchFolder && rid < id {
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
//  1. the row first, in **Starting…**, in its bench folder (r.FolderID, 0 =
//     the home folder) with r.ParentSessionID;
//  2. its place (Place, Prepare): its own worktree of that folder's
//     repository when a live agent already works in that folder (another
//     folder's agents never count) or as r.Place asks, with the .worktreeinclude
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
// refusal of the agent, a bad agent or place, and *workbenchfolders.Refusal:
// a folder not on the bench (not_found), removed (folder_removed, also when
// the remove commits just before the row), not on disk (folder_missing) or,
// other than the home folder, without Watchtower's install (not_installed);
// a parent that is gone (not_found) or another workbench's
// (not_same_workbench). A sub-session's start (r.ParentSessionID) reaches the
// host before its row: with the host down it returns the error and leaves
// no row.
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

// Begin writes a new session's row (Starting…, in its bench folder) and
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
// its agent, target, bench folder (NULL = the home folder; one that left the
// bench fails the row with its refusal) and Claude session id; brief (else the target's
// work-on prompt) and planFirst make the first prompt. A row the host
// already runs is refused. Failures are recorded on the row as Start's are.
func Finish(ctx context.Context, d Deps, sessionID int64, place, brief string, planFirst bool) error {
	choice, err := parseChoice(place)
	if err != nil {
		return err
	}
	var wbID, targetID, runID, folderID sql.NullInt64
	var kind, claudeID, rowFolder string
	err = d.DB.QueryRowContext(ctx, `SELECT project_id, kind, target_id, COALESCE(claude_session_id, ''), automation_run_id,
		workbench_folder_id, folder_path FROM terminal_sessions WHERE id = ? AND `+db.NotDeletingSQL, sessionID).
		Scan(&wbID, &kind, &targetID, &claudeID, &runID, &folderID, &rowFolder)
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
	st := &newStart{d: d, agent: agent, choice: choice, claudeID: claudeID, id: sessionID, automationRun: runID.Int64}
	// A row the host already runs is refused before anything below writes
	// to it: its failure and its folder_path belong to the live run.
	if err := st.refuseIfRunning(ctx); err != nil {
		return err
	}
	if st.wb, err = loadWorkbench(ctx, d.DB, wbID.Int64, folderID.Int64); err != nil {
		var refused *workbenchfolders.Refusal
		if errors.As(err, &refused) {
			st.markFailed(ctx, refused.Error())
		}
		return err
	}
	// The folder may have moved since Begin: gone from disk, the row fails
	// with folder_missing; re-pointed by Locate, the row follows it before
	// its place is decided (one short autocommit UPDATE).
	if err := st.wb.onDisk(); err != nil {
		st.markFailed(ctx, err.Error())
		return err
	}
	if rowFolder != st.wb.folder {
		if _, err := d.DB.ExecContext(ctx, `UPDATE terminal_sessions SET folder_path = ? WHERE id = ? AND worktree_branch IS NULL`,
			st.wb.folder, sessionID); err != nil {
			st.markFailed(ctx, "the session's folder could not be recorded")
			return fmt.Errorf("moving session %d to its folder: %w", sessionID, err)
		}
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
	setStarting(sessionID, &startingRow{workbench: st.wb.id, benchFolder: st.wb.bench.ID, folder: st.wb.folder})
	defer setStarting(sessionID, nil)
	return st.finish(ctx)
}

// refuseIfRunning is ErrAlreadyLaunched when the host runs the row already,
// read before Finish writes anything to it. A host that cannot be reached or
// read is only an error here, never a row write: a lost connection is no
// proof the agent exited (PROJ-20). finish checks again under the placement
// lock.
func (s *newStart) refuseIfRunning(ctx context.Context) error {
	c, done, err := s.d.lease(ctx)
	if err != nil {
		return err
	}
	list, err := c.List(ctx)
	done(err)
	if err != nil {
		return fmt.Errorf("listing the session host: %w", err)
	}
	if info, ok := findRun(list, s.d.scope(), s.id); ok && !info.Exited {
		return ErrAlreadyLaunched
	}
	return nil
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
	wb, err := loadWorkbench(ctx, d.DB, r.Workbench, r.FolderID)
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
		var hidden map[int64]bool
		if d.Hidden != nil {
			hidden = d.Hidden()
		}
		existing, found, err := latestTargetSession(ctx, d.DB, target.id, wb.id, r.Agent, hidden)
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
	if err := wb.checkFolder(); err != nil {
		release()
		return nil, nil, res, err
	}
	if r.ParentSessionID != 0 {
		// The parent is checked first (and again inside the insert's
		// transaction): a bad parent is its refusal, never a host error.
		if err := checkParent(ctx, d.DB, r.ParentSessionID, wb.id); err != nil {
			release()
			return nil, nil, res, err
		}
		// A sub-session's start that cannot reach the host leaves no row
		// behind: the parent's tool call carries the error (spec §7).
		if err := d.probeHost(ctx); err != nil {
			release()
			return nil, nil, res, err
		}
	}
	st = &newStart{d: d, wb: wb, target: target, agent: agent, choice: choice, title: strings.TrimSpace(r.Title),
		automationRun: r.AutomationRunID, parent: r.ParentSessionID}
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

// codexArgs is `launch-args` for the launch of an agent whose hooks arrive
// with its launch flags (sessionagent.Caps.LaunchHooks: Codex; nil for
// Claude); a missing binary is *handlers.AgentNotFoundError.
func codexArgs(ctx context.Context, d Deps, agent agentkind.Kind, wb int64) (*devpack.LaunchArgs, error) {
	if a, ok := sessionagent.For(agent); !ok || !a.Caps().LaunchHooks {
		return nil, nil
	}
	if d.CodexArgs == nil {
		return nil, &handlers.AgentNotFoundError{Agent: string(agent)}
	}
	la, err := d.CodexArgs(ctx, wb)
	if errors.Is(err, devpack.ErrCodexNotFound) {
		return nil, &handlers.AgentNotFoundError{Agent: string(agent)}
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
	// title "" = the default (Begin only); automationRun and parent 0 = none.
	title         string
	automationRun int64
	parent        int64
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

// beforeInsert runs between a start's folder resolution and its row's
// transaction (a test seam for the remove-vs-start race). It is package
// state read by every start: a test that sets it must not run in parallel
// (no t.Parallel) and resets it in t.Cleanup.
var beforeInsert func()

// insert writes the row in its bench folder (Starting…), in one short
// BEGIN IMMEDIATE transaction that re-reads the folder row first (a remove
// that committed since the start resolved it is folder_removed, spec §7)
// and the parent (gone: not_found; another workbench's: not_same_workbench).
func (s *newStart) insert(ctx context.Context) error {
	n := db.NewTerminalSession{WorkbenchID: s.wb.id, Kind: string(s.agent), FolderPath: s.wb.folder,
		Title: ProvisionalTitle(s.d.now()), WorkbenchFolderID: s.wb.bench.ID, ParentSessionID: s.parent}
	if s.target != nil {
		n.TargetID = s.target.id
		n.Title = strings.TrimSpace(s.target.text)
		if n.Title == "" {
			n.Title = "Target #" + strconv.FormatInt(s.target.id, 10)
		}
	}
	if s.title != "" {
		n.Title = s.title
	}
	n.AutomationRunID = s.automationRun
	if a, ok := sessionagent.For(s.agent); ok && a.Caps().AppSessionID {
		s.claudeID = NewSessionID()
		n.ClaudeSessionID = s.claudeID
	}
	if beforeInsert != nil {
		beforeInsert()
	}
	tx, err := s.d.DB.BeginTx(ctx, nil) // BEGIN IMMEDIATE (db.Open's _txlock)
	if err != nil {
		return fmt.Errorf("beginning the start of a session: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if err := s.recheck(ctx, tx); err != nil {
		return err
	}
	id, err := db.CreateTerminalSessionTx(ctx, tx, n)
	if err != nil {
		return err //nolint:wrapcheck // CreateTerminalSession wraps
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing the start of a session: %w", err)
	}
	s.id = id
	setStarting(id, &startingRow{workbench: s.wb.id, benchFolder: s.wb.bench.ID, folder: s.wb.folder})
	return nil
}

// recheck is insert's in-transaction check of the folder and the parent.
func (s *newStart) recheck(ctx context.Context, tx *sql.Tx) error {
	var removed sql.NullString
	err := tx.QueryRowContext(ctx, `SELECT removed_at FROM workbench_folders WHERE id = ? AND workbench_id = ?`,
		s.wb.bench.ID, s.wb.id).Scan(&removed)
	if errors.Is(err, sql.ErrNoRows) {
		return &workbenchfolders.Refusal{Code: workbenchfolders.CodeNotFound,
			Detail: fmt.Sprintf("%s is not a folder of workbench %d.", s.wb.bench.Name, s.wb.id)}
	}
	if err != nil {
		return fmt.Errorf("reading workbench folder %d: %w", s.wb.bench.ID, err)
	}
	if removed.Valid {
		// A legacy bench's fallback home (resolved removed, and the bench
		// still has no live folder) starts there; any other removed folder
		// left the bench since the start resolved it.
		fallback := false
		if s.wb.bench.RemovedAt.Valid {
			if fallback, err = workbenchfolders.IsFallbackHome(ctx, tx, s.wb.bench); err != nil {
				return err //nolint:wrapcheck // names the workbench
			}
		}
		if !fallback {
			return &workbenchfolders.Refusal{Code: workbenchfolders.CodeFolderRemoved, Folder: &s.wb.bench,
				Detail: s.wb.bench.Name + " was removed from the bench."}
		}
	}
	if s.parent == 0 {
		return nil
	}
	return checkParent(ctx, tx, s.parent, s.wb.id)
}

// checkParent refuses a parent that is gone, being deleted or not an agent
// session (not_found), or that is not a session of workbench wb
// (not_same_workbench). q may be the insert's transaction.
func checkParent(ctx context.Context, q db.Querier, parent, wb int64) error {
	var project sql.NullInt64
	var kind string
	err := q.QueryRowContext(ctx, `SELECT project_id, kind FROM terminal_sessions WHERE id = ? AND `+db.NotDeletingSQL,
		parent).Scan(&project, &kind)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && kind == "shell") {
		return &workbenchfolders.Refusal{Code: workbenchfolders.CodeNotFound, Detail: fmt.Sprintf("there is no agent session #%d.", parent)}
	}
	if err != nil {
		return fmt.Errorf("reading session %d: %w", parent, err)
	}
	if !project.Valid || project.Int64 != wb {
		return &workbenchfolders.Refusal{Code: CodeNotSameWorkbench,
			Detail: fmt.Sprintf("session #%d is not a session of workbench %d.", parent, wb)}
	}
	return nil
}

// finish places the row and launches it. A failure after the row exists
// leaves it out of Starting… with the reason in agent_error.
func (s *newStart) finish(ctx context.Context) error {
	c, done, err := s.d.lease(ctx)
	if err != nil {
		s.markFailed(ctx, hostDownReason(err))
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
	// The workbench's placement lock, from the place decision until the run
	// is in the host: another process's start then sees this one's run.
	unlock, err := s.lockPlacement(ctx)
	if err != nil {
		s.markFailed(ctx, LockTimeoutReason)
		return fmt.Errorf("session %d: %w", s.id, err)
	}
	locked := true
	release := func() {
		if locked {
			locked = false
			unlock()
		}
	}
	defer release()
	dir, placed, notice, err := s.place(ctx, c)
	if err != nil {
		hostErr = err
		return err
	}
	s.setNotice(ctx, notice)
	setup, setupNotice := "", ""
	// The bench's worktree_setup is written for its home folder's
	// repository: in v1 it runs only in worktrees of the home folder, and a
	// worktree of any other bench folder runs no setup (multi-folder ruling).
	if placed && s.wb.home && strings.TrimSpace(s.wb.setup) != "" {
		setup = s.wb.setup
		setupNotice = strings.TrimSpace(notice + " " + SetupNotRunPrefix + strings.TrimSpace(setup))
	}
	// Deleted (or its delete requested, #1716) while its place was decided:
	// it never launches.
	var one int
	// Read past a cancelled ctx: the launch below then fails and is recorded.
	err = s.d.DB.QueryRowContext(context.WithoutCancel(ctx), `SELECT 1 FROM terminal_sessions WHERE id = ? AND `+db.NotDeletingSQL,
		s.id).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("Session #%d was deleted before it started.", s.id) //nolint:staticcheck // Swift's sentence, verbatim
	}
	if err != nil {
		s.markFailed(ctx, "the session could not be read before its launch")
		return fmt.Errorf("reading session %d: %w", s.id, err)
	}
	if beforeLaunch != nil {
		beforeLaunch(s.id)
	}
	m := Mode{Agent: string(s.agent), SessionID: s.claudeID, AutomationRunID: s.automationRun}
	if s.prompt != "" {
		p := s.prompt
		m.Prompt = &p
	}
	run, err := launch(ctx, s.d, c, s.id, dir, m, s.codex, setup, setupNotice)
	release()
	if err != nil {
		return err
	}
	// The owner's delete (the Desktop's Undo batch committing) can land
	// between the check above and the launch: a run whose row is gone is
	// stopped at once, never left running; so is a row whose delete was
	// requested meanwhile (#1716).
	if err := s.d.DB.QueryRowContext(context.WithoutCancel(ctx), `SELECT 1 FROM terminal_sessions WHERE id = ? AND `+db.NotDeletingSQL,
		s.id).Scan(&one); errors.Is(err, sql.ErrNoRows) {
		if serr := stopOn(context.WithoutCancel(ctx), c, s.d.scope(), s.id); serr != nil {
			log.Printf("sessionstart: session %d: the run of a deleted row could not be stopped (%s)", s.id, errClass(serr))
		}
		return fmt.Errorf("Session #%d was deleted before it started.", s.id) //nolint:staticcheck // Swift's sentence, verbatim
	}
	return watchLaunch(ctx, s.d, c, s.id, run, s.agent)
}

// setNotice records the start's line for the owner on the row (the
// Desktop's startNotice); best effort — a start never fails over it.
func (s *newStart) setNotice(ctx context.Context, notice string) {
	if err := s.d.DB.SetTerminalSessionStartNotice(context.WithoutCancel(ctx), s.id, notice); err != nil {
		log.Printf("sessionstart: session %d: the start notice was not recorded (%s)", s.id, errClass(err))
	}
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
func notFoundReason(agent agentkind.Kind) string { return AgentNotFoundReason(string(agent)) }

// place moves the row where Place decides, in the workbench's placement
// turn: dir is where it starts, placed whether it went into a worktree made
// for it, notice the owner's line about it ("" = nothing to say). A row that
// could not be moved into its new worktree is failed with MoveFailedPrefix
// and the worktree named (the Desktop then reports it and deletes the
// never-run row); only when even that write fails is the row deleted here.
// The worktree stays on disk either way.
func (s *newStart) place(ctx context.Context, c *sessionhost.Client) (dir string, placed bool, notice string, err error) {
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
		dir, notice = prep.Dir, prep.Notice
		if prep.Worktree == nil {
			return
		}
		if s.d.Integrate != nil {
			// The session runs without it (no hooks or board tools); logged
			// by id and class only (FILES-01), named to the owner in the notice.
			if ierr := s.d.Integrate(ctx, s.wb.id, prep.Dir, s.agent); ierr != nil {
				log.Printf("sessionstart: session %d: worktree integration failed (%s)", s.id, errClass(ierr))
				notice = WorktreeNotice(*prep.Worktree, logredact.Full(ierr))
			}
		}
		// The worktree exists: its row is moved even when the caller gave up.
		bg := context.WithoutCancel(ctx)
		if perr := s.d.DB.PlaceTerminalSession(bg, s.id, prep.Dir, prep.Worktree.Branch, prep.Worktree.Base); perr != nil {
			reason := MoveFailedPrefix + logredact.Full(perr) + " — the worktree " + prep.Dir + " on " +
				prep.Worktree.Branch + " was kept."
			// agent_error is clipped (launchErrorRunes): the whole sentence
			// goes in start_notice, which the Desktop reports.
			nerr := s.d.DB.SetTerminalSessionStartNotice(bg, s.id, reason)
			if ferr := s.d.DB.SetTerminalSessionLaunchError(bg, s.id, reason, s.d.now()); ferr != nil || nerr != nil {
				_, _ = s.d.DB.ExecContext(bg, `DELETE FROM terminal_sessions WHERE id = ?`, s.id)
			}
			err = fmt.Errorf("could not move session %d into its worktree (the worktree was kept): %w", s.id, perr)
			return
		}
		placed = true
		setStarting(s.id, &startingRow{workbench: s.wb.id, benchFolder: s.wb.bench.ID, folder: prep.Dir, branch: prep.Worktree.Branch})
	})
	return dir, placed, notice, err
}

// agentRow is a workbench agent row as the folder check reads it.
type agentRow struct {
	id                  int64
	folder, branch, cwd string
	cwdAt               string
}

// occupied reports whether a live agent already works in the start's bench
// folder (SessionStartPlacement.occupies over the live agent rows of that
// folder and its earlier starts still launching; another folder's agents
// never count, spec 2026-11-18 §6.4) and how many such rows work in it (the
// worktree's session number is one more). A live run
// of a kind this version does not know (a newer version's, adopted from the
// host) may be an agent and counts too (A7b, TerminalCenter.liveAgentIDs'
// mayRunAgent).
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
	args := append(workbenchfolders.SessionRowsArgs(s.wb.bench, s.wb.home), s.id)
	rows, err := s.d.DB.QueryContext(ctx, `SELECT id, folder_path, COALESCE(worktree_branch, ''),
		COALESCE(agent_cwd, ''), COALESCE(agent_cwd_at, '')
		FROM terminal_sessions WHERE `+workbenchfolders.SessionRowsSQL+` AND id <> ? AND `+db.NotDeletingSQL, args...)
	if err != nil {
		return false, 0, fmt.Errorf("reading the workbench's sessions: %w", err)
	}
	defer rows.Close()
	starting := startingBefore(s.wb.id, s.wb.bench.ID, s.id)
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
// in a worktree whose folder is sessionFolder (the start's bench folder) is.
func occupies(branch, folder, cwd, sessionFolder string) bool {
	if cwd != "" {
		return WorktreeTop(cwd) == ""
	}
	return branch == "" && filepath.Clean(folder) == filepath.Clean(sessionFolder)
}

// hostDownReason is the row's reason when no host answers: a Linux start
// that systemd-run refused names its class (no detached spawn follows).
func hostDownReason(err error) string {
	const down = "the session host is not running"
	var um *sessionhost.UserManagerError
	if errors.As(err, &um) {
		return down + ": no systemd user manager (" + um.Class + ")"
	}
	return down
}

func (s *newStart) markFailed(ctx context.Context, reason string) {
	_ = s.d.DB.SetTerminalSessionLaunchError(context.WithoutCancel(ctx), s.id, reason, s.d.now())
}

// launch builds the argv (Launch) and hands it to session-host. A refused
// launch is recorded on the row (agent_error) and returned; failNotice, when
// set, replaces the row's start_notice first (the setup command that never
// ran), so a reader that sees the failure sees the notice too.
func launch(ctx context.Context, d Deps, c *sessionhost.Client, row int64, dir string, m Mode,
	codex *devpack.LaunchArgs, setup, failNotice string,
) (run string, err error) {
	failed := func(reason string) {
		bg := context.WithoutCancel(ctx)
		if failNotice != "" {
			_ = d.DB.SetTerminalSessionStartNotice(bg, row, failNotice)
		}
		_ = d.DB.SetTerminalSessionLaunchError(bg, row, reason, d.now())
	}
	shell := d.Shell
	if shell == "" {
		shell = os.Getenv("SHELL")
	}
	spec, err := Launch(m, row, dir, shell, codex, setup)
	if err != nil {
		failed("the launch could not be built")
		return "", err
	}
	run = NewSessionID()
	_, err = c.Launch(ctx, sessionhost.LaunchReq{
		Row: row, Run: run, Executable: spec.Executable, Args: spec.Args,
		Env: append(baseEnv(spec.Executable), spec.Env...), Cwd: spec.Dir, Cols: launchCols, Rows: launchRows,
		Scope: d.scope(), Agent: m.Agent, Watch: watchSpec(d, m.Agent),
	})
	if err != nil {
		failed(launchFailure(err))
		return "", fmt.Errorf("session %d did not launch: %w", row, err)
	}
	return run, nil
}

// watchSpec is the host's watch request for a launch of agent
// (TerminalCenter.watchSpec's twin, spec 2026-11-05 §3.5): an agent whose
// failed and interrupted turns are read from its rollout, with the
// workspace database; nil otherwise (a shell, Claude Code, no database).
func watchSpec(d Deps, agent string) *sessionhost.WatchSpec {
	if d.DBPath == "" || !sessionagent.CapsOf(agent).RolloutWatch() {
		return nil
	}
	return &sessionhost.WatchSpec{Agent: agent, Database: d.DBPath}
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
// named, never one of hidden (the Desktop's Undo batch, PROJ-17) nor one
// being deleted (delete_requested_at, #1716). With no
// agent named, a row of a kind this version does not know (a newer
// version's) counts too, so reopen refuses it rather than a new session
// starting beside it (A7b).
func latestTargetSession(ctx context.Context, q *db.DB, target, wb int64, agent string, hidden map[int64]bool) (existingRow, bool, error) {
	rows, err := q.QueryContext(ctx, `SELECT id, kind, folder_path, COALESCE(claude_session_id, '')
		FROM terminal_sessions WHERE target_id = ? AND project_id = ? AND kind <> 'shell'
		  AND (? = '' OR kind = ?) AND `+db.NotDeletingSQL+`
		ORDER BY last_active_at DESC, id DESC`, target, wb, agent, agent)
	if err != nil {
		return existingRow{}, false, fmt.Errorf("reading target %d's sessions: %w", target, err)
	}
	defer rows.Close()
	for rows.Next() {
		r := existingRow{workbench: wb}
		if err := rows.Scan(&r.id, &r.kind, &r.folder, &r.agentSessionID); err != nil {
			return existingRow{}, false, fmt.Errorf("reading target %d's sessions: %w", target, err)
		}
		if !hidden[r.id] {
			return r, true, nil
		}
	}
	if err := rows.Err(); err != nil {
		return existingRow{}, false, fmt.Errorf("reading target %d's sessions: %w", target, err)
	}
	return existingRow{}, false, nil
}

// reopen answers a target's existing session: running in the host already,
// it is answered as is; else it resumes (a Codex row with no id of its own
// yet starts again with no prompt). A row of a kind this version does not
// know is never launched — no shell and no Claude Code in its place (A7b):
// it is *handlers.AgentNotFoundError with that kind, which the hub refuses
// not_supported.
func reopen(ctx context.Context, d Deps, r existingRow) (handlers.StartResult, error) {
	agent := agentkind.Kind(r.kind)
	_, known := agentkind.Parse(r.kind)
	var codex *devpack.LaunchArgs
	if known {
		if err := providers.Allowed(r.kind); err != nil {
			return handlers.StartResult{}, err //nolint:wrapcheck // the policy's own sentence is the message
		}
		var err error
		if codex, err = codexArgs(ctx, d, agent, r.workbench); err != nil {
			return handlers.StartResult{}, err
		}
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
	if !known {
		return handlers.StartResult{}, &handlers.AgentNotFoundError{Agent: r.kind}
	}
	if _, err := d.DB.ExecContext(ctx, `UPDATE terminal_sessions SET last_active_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ?`, r.id); err != nil {
		return handlers.StartResult{}, fmt.Errorf("opening session %d: %w", r.id, err)
	}
	m := Mode{Agent: r.kind, SessionID: r.agentSessionID, Resume: r.agentSessionID != ""}
	run, err := launch(ctx, d, c, r.id, r.folder, m, codex, "", "")
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
