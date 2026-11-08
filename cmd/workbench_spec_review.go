package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
	"watchtower/internal/providers"
	"watchtower/internal/sessionagent"
	"watchtower/internal/sessionfeed"
	"watchtower/internal/specreview"
)

var workbenchSpecReviewCmd = &cobra.Command{
	Use:   "spec-review",
	Short: "The independent reviewer of a spec or plan review ask",
}

var workbenchSpecReviewRunCmd = &cobra.Command{
	Use:    "run --ask N",
	Short:  "Run the reviewer of ask N (the detached child ask_owner and start launch)",
	Hidden: true,
	Args:   cobra.NoArgs,
	RunE:   runSpecReviewRun,
}

var workbenchSpecReviewStartCmd = &cobra.Command{
	Use:   "start --ask N [--force]",
	Short: "Queue the reviewer of ask N and launch it",
	Long: "Queues the spec review of ask N and launches the reviewer in the background. A queued\n" +
		"review is launched again; a running one is refused (exit 3, \"already running\"); a done,\n" +
		"failed or skipped one is run again only with --force (exit 3 without it).",
	Args: cobra.NoArgs,
	RunE: runSpecReviewStart,
}

var workbenchSpecReviewShowCmd = &cobra.Command{
	Use:   "show --ask N [--json]",
	Short: "Show the spec review of ask N and the owner's marks",
	Long: "--json prints {ask_id, status, reason, provider, model, dropped, attempt, queued_at,\n" +
		"started_at, finished_at, result, marks}: result is the validated reviewer result or null,\n" +
		"marks maps each item key to {state, body, about, updated_at} (about: a comment's finding\n" +
		"text, left out when not known). The database is opened read-only.",
	Args: cobra.NoArgs,
	RunE: runSpecReviewShow,
}

var workbenchSpecReviewRevealCmd = &cobra.Command{
	Use:    "reveal --ask N --reason session_gone|owner",
	Short:  "End the author loop of ask N and show it to the owner",
	Hidden: true,
	Args:   cobra.NoArgs,
	RunE:   runSpecReviewReveal,
}

var (
	specReviewFlagReason string
	specReviewFlagAsk    int64
	specReviewFlagForce  bool
	specReviewFlagJSON   bool
)

func init() {
	for _, c := range []*cobra.Command{workbenchSpecReviewRunCmd, workbenchSpecReviewStartCmd, workbenchSpecReviewShowCmd, workbenchSpecReviewRevealCmd} {
		c.Flags().Int64Var(&specReviewFlagAsk, "ask", 0, "owner ask id")
		_ = c.MarkFlagRequired("ask")
		workbenchSpecReviewCmd.AddCommand(c)
	}
	workbenchSpecReviewStartCmd.Flags().BoolVar(&specReviewFlagForce, "force", false, "run a done, failed or skipped review again")
	workbenchSpecReviewRevealCmd.Flags().StringVar(&specReviewFlagReason, "reason", "", "why the loop ends (session_gone, or owner for Show Now)")
	_ = workbenchSpecReviewRevealCmd.MarkFlagRequired("reason")
	workbenchSpecReviewShowCmd.Flags().BoolVar(&specReviewFlagJSON, "json", false, "output JSON")
	workbenchCmd.AddCommand(workbenchSpecReviewCmd)
}

// specReviewAgentFactory builds the reviewer agent; tests swap it so no test
// reaches claude or codex.
var specReviewAgentFactory = func(cfg *config.Config, model string) specreview.Agent {
	return &specReviewCLIAgent{cfg: cfg, model: model}
}

// specReviewCLIAgent is the configured provider in read-folder mode with no
// MCP server at all (no watchtower tools, none of the owner's): claude with
// Read/Grep/Glob/LS only and no folder settings, codex under its read-only
// sandbox, both in their own process group. Ollama has no file tools: the
// same prompt, answered from the data alone.
type specReviewCLIAgent struct {
	cfg   *config.Config
	model string
}

func (a *specReviewCLIAgent) Review(ctx context.Context, folder, system, user string) (string, bool, error) {
	ctx = digest.WithSource(ctx, specreview.ModelSource)
	if provider := providers.ByID(a.cfg.AI.Provider); !provider.Caps.ReadsFolder() {
		// A transport with no file tools answers from the prompt's data.
		out, _, _, err := cliBoundedGenerator(a.cfg).Generate(ctx, system, user, "")
		return out, false, wrapSpecReviewErr(provider.ID+" reviewer", err)
	}
	if folder == "" {
		// Never a file-reading run outside read-folder mode.
		return "", false, errors.New("no folder to read")
	}
	out, err := specReviewReadFolder(ctx, a.cfg, a.model, folder, system, user)
	return out, true, err
}

// specReviewCodexHome is the codex reviewer's private CODEX_HOME, a fresh
// 0700 temp folder the caller removes after the run: it holds the run's
// rollout, so the review never reaches the owner's codex history. The
// owner's sign-in and config.toml (model provider, profiles; its MCP
// servers are switched off by SetNoMCPServers) are linked, never copied.
// An owner signed in without an auth.json (codex's keyring store, which is
// tied to the home) gets "": the reviewer keeps the owner's home, as before,
// and its cap counts the stream (remove is then a no-op).
func specReviewCodexHome() (dir string, remove func(), err error) {
	_, err = os.Stat(filepath.Join(ownerCodexHome(), "auth.json"))
	if errors.Is(err, fs.ErrNotExist) {
		log.Printf("codex reviewer: no auth.json in the codex home; it runs there and its turn cap counts the stream")
		return "", func() {}, nil
	}
	return newCodexHome("wt-review-codex-home-*", "auth.json", "config.toml")
}

// wrapSpecReviewErr names the reviewer a failure came from; nil stays nil.
func wrapSpecReviewErr(what string, err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("%s: %w", what, err)
}

func runSpecReviewRun(cmd *cobra.Command, _ []string) error {
	cfg, err := loadWorkbenchCLIConfig()
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	applyProviderOverride(cfg)
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	id := specReviewFlagAsk
	cfg, strong, selectionErr := specReviewSessionConfig(cmd.Context(), database, id, cfg)
	var agent specreview.Agent
	if selectionErr != nil {
		agent = specReviewSelectionFailure{err: fmt.Errorf("choosing reviewer: %w", selectionErr)}
	} else {
		agent = specReviewAgentFactory(cfg, strong)
	}
	provider := cfg.AI.Provider
	store := prompts.New(database, nil)
	deps := specreview.Deps{
		DB:    database,
		Agent: agent,
		Prompt: func() string {
			tmpl, _, err := prompts.Resolve(store, prompts.SpecReview, "")
			if err != nil {
				fmt.Fprintf(cmd.ErrOrStderr(), "spec-review: prompt: %v (using the built-in one)\n", err)
			}
			return tmpl
		},
		Feed:     specReviewFeed(database),
		Now:      time.Now,
		PID:      os.Getpid(),
		Provider: provider,
		Model:    strong,
	}
	parent := cmd.Context()
	if parent == nil {
		parent = context.Background()
	}
	// SIGINT/SIGTERM cancel the model call, which kills its process group.
	ctx, stop := notifyShutdownContext(parent, stderrLogf)
	defer stop()
	if err := specreview.Run(ctx, deps, id); err != nil {
		return fmt.Errorf("spec review of ask %d: %w", id, err)
	}
	return nil
}

// specReviewFeed reads a session's chat the way `workbench session-feed`
// does; a shell session or a missing one is an error the run turns into a note.
func specReviewFeed(database *db.DB) func(context.Context, int64) ([]sessionfeed.Entry, error) {
	return func(ctx context.Context, id int64) ([]sessionfeed.Entry, error) {
		sess, err := sessionagent.LoadSession(database, id)
		if err != nil {
			return nil, fmt.Errorf("session %d: %w", id, err)
		}
		if err := requireAgentSession(sess); err != nil {
			return nil, fmt.Errorf("session %d: %w", id, err)
		}
		convs, err := sessionFeedConversations(ctx, database, sess)
		if err != nil {
			return nil, fmt.Errorf("session %d conversations: %w", id, err)
		}
		feed, err := sessionfeed.Build(convs, nil, sessionFeedAskLookup(database, sess.WorkbenchID))
		if err != nil {
			return nil, fmt.Errorf("session %d feed: %w", id, err)
		}
		return feed.Entries, nil
	}
}

func runSpecReviewStart(cmd *cobra.Command, _ []string) error {
	cfg, err := loadWorkbenchCLIConfig()
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	id := specReviewFlagAsk
	ask, err := database.GetOwnerAskByID(id)
	if err != nil {
		return fmt.Errorf("loading ask %d: %w", id, err)
	}
	if t := specreview.DocType(ask.DocType); ask.Kind != "review" || (t != specreview.Spec && t != specreview.Plan) {
		return usageError("ask %d is not a spec or plan review", id)
	}
	// The owner pressed Run.
	if err := database.RequeueSpecReview(id, specReviewFlagForce, time.Now()); err != nil {
		if errors.Is(err, db.ErrSpecReviewBusy) {
			return &exitCodeError{code: 3, err: fmt.Errorf("spec review of ask %d: %w", id, err)}
		}
		return fmt.Errorf("re-queueing spec review of ask %d: %w", id, err)
	}
	exe, err := specReviewExe()
	if err != nil {
		return fmt.Errorf("locating the watchtower binary: %w", err)
	}
	// A failed launch leaves the row queued: the daemon sweep starts it.
	if err := LaunchSpecReview(exe, id, filepath.Join(cfg.WorkspaceDir(), "logs")); err != nil {
		return fmt.Errorf("launching spec review of ask %d: %w", id, err)
	}
	fmt.Fprintf(cmd.OutOrStdout(), "spec review of ask %d started\n", id)
	return nil
}

// specReviewShowJSON is the pinned output of `spec-review show --json`.
type specReviewShowJSON struct {
	AskID      int64                         `json:"ask_id"`
	Status     string                        `json:"status"`
	Reason     string                        `json:"reason"`
	Provider   string                        `json:"provider"`
	Model      string                        `json:"model"`
	Dropped    int                           `json:"dropped"`
	Attempt    int                           `json:"attempt"`
	QueuedAt   string                        `json:"queued_at"`
	StartedAt  string                        `json:"started_at"`
	FinishedAt string                        `json:"finished_at"`
	Result     json.RawMessage               `json:"result"` // null until done
	Marks      map[string]specReviewMarkJSON `json:"marks"`
	Loop       string                        `json:"loop"`
	Round      int                           `json:"round"`
	LoopEnd    string                        `json:"loop_end"`
	OpenItems  json.RawMessage               `json:"open_items"`
	Ledger     json.RawMessage               `json:"ledger"`
}

type specReviewMarkJSON struct {
	State     string `json:"state"`
	Body      string `json:"body"`
	About     string `json:"about,omitempty"`
	UpdatedAt string `json:"updated_at"`
}

func runSpecReviewShow(cmd *cobra.Command, _ []string) error {
	cfg, err := loadWorkbenchCLIConfig()
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	database, err := db.OpenExisting(cfg.DBPath(), sessionFeedBusyTimeout)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	id := specReviewFlagAsk
	row, err := database.GetSpecReview(id)
	if errors.Is(err, db.ErrSpecReviewNotFound) {
		return fmt.Errorf("ask %d has no spec review", id)
	}
	if err != nil {
		return fmt.Errorf("reading spec review of ask %d: %w", id, err)
	}
	marks, err := database.ListSpecReviewMarks(id)
	if err != nil {
		return fmt.Errorf("reading spec review marks of ask %d: %w", id, err)
	}
	out := specReviewShowJSON{
		AskID: row.AskID, Status: row.Status, Reason: row.Reason, Provider: row.Provider, Model: row.Model,
		Dropped: row.Dropped, Attempt: row.Attempt, QueuedAt: row.QueuedAt, StartedAt: row.StartedAt,
		FinishedAt: row.FinishedAt, Marks: map[string]specReviewMarkJSON{},
		Loop: row.Loop, Round: row.Round, LoopEnd: row.LoopEnd,
		OpenItems: listOrEmpty(row.OpenItems), Ledger: listOrEmpty(row.Ledger),
	}
	if row.Result != "" {
		out.Result = json.RawMessage(row.Result)
	}
	for k, m := range marks {
		out.Marks[k] = specReviewMarkJSON{State: m.State, Body: m.Body, About: m.About, UpdatedAt: m.UpdatedAt}
	}
	w := cmd.OutOrStdout()
	if specReviewFlagJSON {
		return writeJSON(w, out)
	}
	fmt.Fprintf(w, "ask %d: %s", id, row.Status)
	if row.Reason != "" {
		fmt.Fprintf(w, " (%s)", row.Reason)
	}
	fmt.Fprintf(w, ", attempt %d, %d findings dropped, %d marks\n", row.Attempt, row.Dropped, len(marks))
	return nil
}

// listOrEmpty is a loop column as a JSON array: [] when the column is empty.
func listOrEmpty(s string) json.RawMessage {
	if s == "" {
		return json.RawMessage("[]")
	}
	return json.RawMessage(s)
}

// runSpecReviewReveal ends ask N's author loop for the one reason a caller
// outside the daemon knows: the asking session is gone. A row already shown
// to the owner is left as it is (exit 0).
func runSpecReviewReveal(cmd *cobra.Command, _ []string) error {
	if specReviewFlagReason != specreview.EndSessionGone && specReviewFlagReason != specreview.EndOwner {
		return usageError("--reason must be %s or %s", specreview.EndSessionGone, specreview.EndOwner)
	}
	cfg, err := loadWorkbenchCLIConfig()
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()
	id := specReviewFlagAsk
	if err := specreview.Reveal(database, id, specReviewFlagReason, time.Now()); err != nil {
		return fmt.Errorf("revealing spec review of ask %d: %w", id, err)
	}
	fmt.Fprintf(cmd.OutOrStdout(), "spec review of ask %d revealed\n", id)
	return nil
}

// Route discovery failures through Run so it claims and fails the queued review normally.
type specReviewSelectionFailure struct{ err error }

func (a specReviewSelectionFailure) Review(context.Context, string, string, string) (string, bool, error) {
	return "", false, a.err
}
