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

// Agent is the reviewer model: a read-only run in folder (the one Run
// resolved, never empty) over system and user that returns the raw reply and
// whether it could open files in the folder.
type Agent interface {
	Review(ctx context.Context, folder, system, user string) (raw string, codeRead bool, err error)
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

// errAskWithdrawn fails a review whose ask was withdrawn (or superseded by a
// new round) before the reviewer claimed it: nobody will read the result.
var errAskWithdrawn = errors.New("ask withdrawn")

// Run reviews ask askID: it claims the queued row (a lost claim does nothing),
// fails it at once when the ask is already withdrawn, builds the inputs, calls the agent under RunTimeout, validates the reply
// and stores it. Any failure after the claim marks the row failed with a
// one-line reason. On an author-loop row the result also advances the loop
// (NextRound), and a failure reveals the ask (Reveal, reviewer_failed). Run
// writes nothing but the ask's spec_reviews row.
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
		// A failed author-loop round shows the ask to the owner at once. A
		// withdrawn ask was superseded: the loop goes on in the next round,
		// which reads this row.
		if !errors.Is(err, errAskWithdrawn) {
			if rerr := Reveal(d.DB, askID, EndReviewerFailed, d.Now()); rerr != nil {
				return errors.Join(err, rerr)
			}
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
	row, err := d.DB.GetSpecReview(askID)
	if err != nil {
		return db.SpecReview{}, err
	}
	// Checked once, at the start: an ask withdrawn while the agent works
	// still gets its result.
	if ask.Status == "withdrawn" {
		return db.SpecReview{}, errAskWithdrawn
	}
	t := DocType(ask.DocType)
	if ask.Kind != "review" || (t != Spec && t != Plan) {
		return db.SpecReview{}, fmt.Errorf("ask %d is not a spec or plan review", askID)
	}
	folder, err := readFolder(d.DB, ask)
	if err != nil {
		return db.SpecReview{}, err
	}
	src, user, notes, err := BuildInputs(ctx, d, ask, folder)
	if err != nil {
		return db.SpecReview{}, err
	}
	callCtx, cancel := context.WithTimeout(ctx, RunTimeout)
	defer cancel()
	raw, codeRead, err := d.Agent.Review(callCtx, folder, d.Prompt(), user)
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
	out := db.SpecReview{
		Result: string(js), Provider: d.Provider, Model: d.Model,
		DocSHA: hex.EncodeToString(sum[:]), Dropped: res.Dropped,
		Findings: len(res.DecidedAlone) + len(res.BlindSpots) + len(res.Checks),
	}
	if row.Loop == "author" {
		if err := advanceLoop(d.DB, ask, row, res, &out); err != nil {
			return db.SpecReview{}, err
		}
	}
	return out, nil
}

// advanceLoop sets out's loop columns from NextRound: the previous round's
// open items and ledger (read from the previous ask's row) and this row's
// replies. The loop stays with the author ("author") until the round ends
// it ("owner").
func advanceLoop(d *db.DB, ask *db.OwnerAsk, row *db.SpecReview, res Result, out *db.SpecReview) error {
	var prevLedger []LedgerEntry
	var prevOpen []AuthorItem
	if row.Round >= 2 && ask.PreviousAskID.Valid {
		prev, err := d.GetSpecReview(ask.PreviousAskID.Int64)
		if err != nil && !errors.Is(err, db.ErrSpecReviewNotFound) {
			return err
		}
		if prev != nil {
			if prevLedger, prevOpen, err = decodeLoop(prev); err != nil {
				return err
			}
		}
	}
	replies, err := decodeReplies(row.Replies)
	if err != nil {
		return err
	}
	o := NextRound(row.Round, prevOpen, prevLedger, replies, res)
	if out.OpenItems, err = encodeList(o.Open); err != nil {
		return err
	}
	if out.Ledger, err = encodeList(o.Ledger); err != nil {
		return err
	}
	out.Loop, out.LoopEnd = "author", o.End
	if o.End != "" {
		out.Loop = "owner"
	}
	return nil
}

// readFolder is where the reviewer reads: the session's working directory (its
// worktree) when it is recorded and still a directory, else the workbench
// folder, which must be a directory too: the reviewer never runs without one.
func readFolder(d *db.DB, ask *db.OwnerAsk) (string, error) {
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
	if wb.FolderPath == "" {
		return "", fmt.Errorf("workbench %d has no folder to read", ask.WorkbenchID)
	}
	if st, err := os.Stat(wb.FolderPath); err != nil || !st.IsDir() {
		return "", fmt.Errorf("the workbench folder %s is not a readable directory", wb.FolderPath)
	}
	return wb.FolderPath, nil
}

// oneLine is err's text on one line, clipped for the screen.
func oneLine(err error) string {
	return clip(Normalize(err.Error()), maxReasonRunes)
}
