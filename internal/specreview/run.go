package specreview

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/sessionfeed"
)

// Run budget (spec §3): wall clock of the model call and the turn cap of a
// claude run.
const (
	RunTimeout = 10 * time.Minute
	MaxTurns   = 40
)

// ModelSource is the model-routing tag of the reviewer's call (strong tier).
const ModelSource = "workbench.spec_review"

// maxReasonRunes bounds a failure reason: one line on the screen.
const maxReasonRunes = 300

// Agent is the reviewer model: a read-only run over system and user that
// returns the raw reply and whether it could open files in the folder.
type Agent interface {
	Review(ctx context.Context, system, user string) (raw string, codeRead bool, err error)
}

// Deps is what a run needs. Provider and Model are stored with the result.
type Deps struct {
	DB       *db.DB
	Agent    Agent
	Prompt   func() string
	Feed     func(ctx context.Context, sessionID int64) ([]sessionfeed.Entry, error)
	Now      func() time.Time
	PID      int
	Provider string
	Model    string
}

// Run reviews ask askID: it claims the queued row (a lost claim does nothing),
// builds the inputs, calls the agent under RunTimeout, validates the reply
// and stores it. Any failure after the claim marks the row failed with a
// one-line reason. Run writes nothing but the ask's spec_reviews row.
func Run(ctx context.Context, d Deps, askID int64) error {
	claimed, err := d.DB.ClaimSpecReview(askID, d.PID, d.Now())
	if err != nil {
		return err
	}
	if !claimed {
		return nil
	}
	review, err := run(ctx, d, askID)
	if err != nil {
		if ferr := d.DB.FailSpecReview(askID, d.PID, oneLine(err), d.Now()); ferr != nil {
			return errors.Join(err, ferr)
		}
		return err
	}
	return d.DB.FinishSpecReview(askID, d.PID, review, d.Now())
}

func run(ctx context.Context, d Deps, askID int64) (db.SpecReview, error) {
	ask, err := d.DB.GetOwnerAskByID(askID)
	if err != nil {
		return db.SpecReview{}, err
	}
	t := DocType(ask.DocType)
	if ask.Kind != "review" || (t != Spec && t != Plan) {
		return db.SpecReview{}, fmt.Errorf("ask %d is not a spec or plan review", askID)
	}
	folder, err := Folder(d.DB, ask)
	if err != nil {
		return db.SpecReview{}, err
	}
	src, user, notes, err := BuildInputs(ctx, d, ask, folder)
	if err != nil {
		return db.SpecReview{}, err
	}
	callCtx, cancel := context.WithTimeout(ctx, RunTimeout)
	defer cancel()
	raw, codeRead, err := d.Agent.Review(callCtx, d.Prompt(), user)
	if err != nil {
		if errors.Is(callCtx.Err(), context.DeadlineExceeded) {
			return db.SpecReview{}, fmt.Errorf("the reviewer ran out of time (%s): %w", RunTimeout, err)
		}
		return db.SpecReview{}, fmt.Errorf("the reviewer failed: %w", err)
	}
	res, err := Parse(raw, src, t)
	if err != nil {
		return db.SpecReview{}, err
	}
	res.CodeRead = codeRead
	res.Notes = append(notes, res.Notes...)
	if len(res.Notes) > maxNotes {
		res.Notes = res.Notes[:maxNotes]
	}
	js, err := json.Marshal(res)
	if err != nil {
		return db.SpecReview{}, fmt.Errorf("encoding the result: %w", err)
	}
	sum := sha256.Sum256([]byte(ask.DocSnapshot))
	return db.SpecReview{
		Result: string(js), Provider: d.Provider, Model: d.Model,
		DocSHA: hex.EncodeToString(sum[:]), Dropped: res.Dropped,
	}, nil
}

// Folder is where the reviewer reads: the session's working directory (its
// worktree) when it is recorded and still a directory, else the workbench
// folder.
func Folder(d *db.DB, ask *db.OwnerAsk) (string, error) {
	if ask.SessionID.Valid {
		cwd, err := d.TerminalAgentCwd(ask.SessionID.Int64)
		if err != nil {
			return "", err
		}
		if cwd.Path != "" {
			if st, err := os.Stat(cwd.Path); err == nil && st.IsDir() {
				return cwd.Path, nil
			}
		}
	}
	wb, err := d.GetWorkbench(ask.WorkbenchID)
	if err != nil {
		return "", err
	}
	return wb.FolderPath, nil
}

// oneLine is err's text on one line, clipped for the screen.
func oneLine(err error) string {
	return clip(Normalize(err.Error()), maxReasonRunes)
}
