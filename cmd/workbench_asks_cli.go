package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/asks"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

var workbenchAsksCmd = &cobra.Command{
	Use:   "asks",
	Short: "List the owner asks of every workbench (or one) as JSON, for other clients",
	Long: "--json prints one JSON object {\"ok\": true, \"asks\": [...]}: every ask of every workbench,\n" +
		"or of --workbench N only; --open keeps the open ones. Each ask carries its stored level\n" +
		"(quick | full; clients never classify), origin and chat_asked_at, its workbench and\n" +
		"session names, and its questions with their options (kind question), or checklist_count\n" +
		"(kind check) and doc_path (kind review). An ask whose payload does not parse is listed\n" +
		"with payload_error and no questions; the others are unaffected. Any other failure prints\n" +
		"{\"ok\": false, \"error\"} — a missing database or one older than migration 00107 too;\n" +
		"both exit 0. Only arguments cobra cannot parse (a missing --json, an unknown flag, a\n" +
		"positional argument) exit non-zero, with no JSON. Read-only: it never creates or\n" +
		"migrates the database; answering is done in the Desktop.",
	// No root schema/config pre-run: a broken config answers ok: false like
	// any other failure; the DB is opened by the command.
	PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
	Args:              cobra.NoArgs,
	RunE:              runWorkbenchAsks,
}

var (
	workbenchAsksFlagWorkbench int64
	workbenchAsksFlagOpen      bool
	workbenchAsksFlagJSON      bool
)

func init() {
	c := workbenchAsksCmd
	addWorkbenchIDFlag(c, &workbenchAsksFlagWorkbench, "workbench id (default: every workbench)")
	fs := c.Flags()
	fs.BoolVar(&workbenchAsksFlagOpen, "open", false, "only the open asks")
	fs.BoolVar(&workbenchAsksFlagJSON, "json", false, "output JSON (required: the only output)")
	_ = c.MarkFlagRequired("json")
	workbenchCmd.AddCommand(c)
}

// asksListJSON is `workbench asks --json`'s envelope (spec 2026-10-10 Part
// 10.1); the mobile companion decodes these exact keys.
type asksListJSON struct {
	OK   bool          `json:"ok"`
	Asks []askListJSON `json:"asks"`
}

type asksListFailure struct {
	OK    bool   `json:"ok"`
	Error string `json:"error"`
}

type askListJSON struct {
	ID            int64  `json:"id"`
	WorkbenchID   int64  `json:"workbench_id"`
	WorkbenchName string `json:"workbench_name"`
	SessionID     *int64 `json:"session_id"`    // null: an external terminal or a gone session
	SessionTitle  string `json:"session_title"` // "" with no session row
	Kind          string `json:"kind"`
	Level         string `json:"level"`
	Origin        string `json:"origin"`
	ChatAskedAt   string `json:"chat_asked_at"` // origin chat only; "" otherwise
	Status        string `json:"status"`
	CreatedAt     string `json:"created_at"`
	Title         string `json:"title"`
	Summary       string `json:"summary"`
	// Questions: kind question only, and only when the payload parses.
	Questions []askQuestionJSON `json:"questions,omitempty"`
	// ChecklistCount: kind check only, and only when the payload parses.
	ChecklistCount *int   `json:"checklist_count,omitempty"`
	DocPath        string `json:"doc_path,omitempty"` // kind review only
	// PayloadError is why the stored payload did not parse; "" when it did.
	PayloadError string `json:"payload_error,omitempty"`
}

type askQuestionJSON struct {
	ID       string          `json:"id"`
	Question string          `json:"question"`
	Multi    bool            `json:"multi"`
	Options  []askOptionJSON `json:"options"`
}

type askOptionJSON struct {
	Label       string `json:"label"`
	Description string `json:"description"`
	Recommended bool   `json:"recommended"`
}

func runWorkbenchAsks(cmd *cobra.Command, _ []string) error {
	out := cmd.OutOrStdout()
	if err := checkWorkbenchIDFlags(cmd); err != nil {
		return writeJSON(out, asksListFailure{OK: false, Error: err.Error()})
	}
	// An id flag given is a workbench to filter by: 0 there is a mistake,
	// never "every workbench".
	fs := cmd.Flags()
	if legacy := fs.Changed(legacyWorkbenchFlag); (legacy || fs.Changed(workbenchFlag)) && workbenchAsksFlagWorkbench <= 0 {
		return writeJSON(out, asksListFailure{OK: false, Error: workbenchFlagName(legacy) + " takes a positive id"})
	}
	list, err := listAsksForClients(workbenchAsksFlagWorkbench, workbenchAsksFlagOpen)
	if err != nil {
		return writeJSON(out, asksListFailure{OK: false, Error: err.Error()})
	}
	return writeJSON(out, asksListJSON{OK: true, Asks: list})
}

// listAsksForClients reads the asks of workbench workbenchID (0 = every
// workbench, in id order), each workbench's in ListOwnerAsks' order; open
// keeps the open ones, otherwise every status is listed.
func listAsksForClients(workbenchID int64, open bool) ([]askListJSON, error) {
	database, err := openAsksDB()
	if err != nil {
		return nil, err
	}
	defer database.Close()
	var workbenches []db.Workbench
	if workbenchID > 0 {
		w, err := database.GetWorkbench(workbenchID)
		if err != nil {
			return nil, err
		}
		workbenches = []db.Workbench{*w}
	} else if workbenches, err = database.ListWorkbenches(); err != nil {
		return nil, err
	}
	statuses := []string{"open", "answered", "delivered", "withdrawn"}
	if open {
		statuses = []string{"open"}
	}
	titles := map[int64]string{}
	list := []askListJSON{}
	for _, w := range workbenches {
		rows, err := database.ListOwnerAsks(w.ID, db.OwnerAskFilter{Statuses: statuses})
		if err != nil {
			return nil, err
		}
		for _, a := range rows {
			title, err := askSessionTitle(database, a, titles)
			if err != nil {
				return nil, err
			}
			list = append(list, toAskListJSON(a, w.Name, title))
		}
	}
	return list, nil
}

// asksBusyTimeout is how long a read of the asks waits out another process's
// write lock.
const asksBusyTimeout = 2 * time.Second

// openAsksDB opens the active workspace's database read-only: it never
// creates the file and never migrates (db.OpenExisting). A schema without the
// 00107 ask columns is refused, so an older database fails clearly instead
// of on the first query.
func openAsksDB() (*db.DB, error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return nil, fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return nil, err
	}
	database, err := db.OpenExisting(cfg.DBPath(), asksBusyTimeout)
	if err != nil {
		return nil, err
	}
	ok, err := database.HasColumns("owner_asks", "level", "origin", "chat_asked_at", "withdrawn_at")
	if err == nil && !ok {
		err = errors.New("the database predates the ask levels (migration 00107): open the Watchtower app to upgrade it")
	}
	if err != nil {
		database.Close()
		return nil, err
	}
	return database, nil
}

// askSessionTitle is the title of a's terminal session, "" when it has none
// or the row is gone; titles caches the lookups by session id.
func askSessionTitle(database *db.DB, a db.OwnerAsk, titles map[int64]string) (string, error) {
	if !a.SessionID.Valid {
		return "", nil
	}
	id := a.SessionID.Int64
	if t, ok := titles[id]; ok {
		return t, nil
	}
	s, err := database.GetTerminalSession(id)
	switch {
	case errors.Is(err, db.ErrTerminalSessionNotFound):
		titles[id] = ""
	case err != nil:
		return "", err
	default:
		titles[id] = s.Title
	}
	return titles[id], nil
}

func toAskListJSON(a db.OwnerAsk, workbenchName, sessionTitle string) askListJSON {
	out := askListJSON{ID: a.ID, WorkbenchID: a.WorkbenchID, WorkbenchName: workbenchName,
		SessionID: nullableID(a.SessionID), SessionTitle: sessionTitle, Kind: a.Kind, Level: a.Level,
		Origin: a.Origin, ChatAskedAt: a.ChatAskedAt, Status: a.Status, CreatedAt: a.CreatedAt,
		Title: a.Title, Summary: a.Summary}
	if a.Kind == asks.KindReview {
		out.DocPath = a.DocPath
	}
	var p asks.Payload
	if err := json.Unmarshal([]byte(a.Payload), &p); err != nil {
		out.PayloadError = fmt.Sprintf("unreadable payload: %v", err)
		return out
	}
	switch a.Kind {
	case asks.KindQuestion:
		out.Questions = make([]askQuestionJSON, 0, len(p.Questions))
		for _, q := range p.Questions {
			opts := make([]askOptionJSON, 0, len(q.Options))
			for _, o := range q.Options {
				opts = append(opts, askOptionJSON{Label: o.Label, Description: o.Description, Recommended: o.Recommended})
			}
			out.Questions = append(out.Questions, askQuestionJSON{ID: q.ID, Question: q.Question, Multi: q.Multi, Options: opts})
		}
	case asks.KindCheck:
		n := len(p.Checklist)
		out.ChecklistCount = &n
	}
	return out
}
