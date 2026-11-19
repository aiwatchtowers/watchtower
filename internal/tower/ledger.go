package tower

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"

	"watchtower/internal/db"
	"watchtower/internal/tower/api"
)

// errAlreadyDone is what Write returns to a guarded handler when another
// call with the same request_id committed first: the write rolled back, and
// Call answers that call's stored result.
var errAlreadyDone = errors.New("tower: the request was already applied")

// callWrite runs a write command through the request ledger:
//   - a repeat of a done id answers the stored result without running;
//   - a guarded (idempotent) command writes its done row inside its own
//     write transaction (Ctx.Write), so done exists exactly when the write
//     committed, and a begun row is re-run;
//   - a non-idempotent command commits a begun row in its own short
//     transaction before it acts; a repeat of begun answers unknown.
func (t *Tower) callWrite(ctx context.Context, resp api.Response, c *Ctx,
	run func(context.Context, *Ctx) (any, error), params json.RawMessage) api.Response {
	var wp api.WriteParams
	if err := json.Unmarshal(params, &wp); err != nil || wp.RequestID == "" {
		return refused(resp, api.CodeUnsupported, "Watchtower couldn't apply this: the request has no id. Update the app.")
	}
	guarded, err := t.opts.Registry.IsIdempotent(c.command, params)
	if err != nil {
		return t.fail(resp, c.command, err)
	}
	c.requestID, c.guarded = wp.RequestID, guarded
	row, err := t.db.GetTowerRequest(ctx, c.requestID)
	if err != nil {
		return t.fail(resp, c.command, err)
	}
	if row != nil {
		switch {
		case row.Command != c.command:
			return refused(resp, api.CodeUnsupported, "Watchtower couldn't apply this: the request id belongs to another action.")
		case row.State == "done":
			return t.storedAnswer(resp, c.command, row)
		case !guarded:
			return unknown(resp)
		}
	}
	if guarded {
		return t.runGuarded(ctx, resp, c, run)
	}
	return t.runOnce(ctx, resp, c, run)
}

func (t *Tower) runGuarded(ctx context.Context, resp api.Response, c *Ctx,
	run func(context.Context, *Ctx) (any, error)) api.Response {
	out, err := run(ctx, c)
	if c.stored != nil {
		return ok(resp, c.stored)
	}
	if err != nil {
		// Nothing committed: a resend may succeed.
		return t.fail(resp, c.command, err)
	}
	// The handler never called Write: record done after it.
	b, err := json.Marshal(out)
	if err != nil {
		return t.fail(resp, c.command, fmt.Errorf("marshal the response: %w", err))
	}
	err = t.ledgerTx(ctx, func(tx *sql.Tx) error {
		return db.FinishTowerRequestTx(tx, c.requestID, c.command, string(b), c.Now())
	})
	if errors.Is(err, db.ErrTowerRequestExists) {
		return t.storedResult(ctx, resp, c)
	}
	if err != nil {
		return t.fail(resp, c.command, err)
	}
	return ok(resp, b)
}

func (t *Tower) runOnce(ctx context.Context, resp api.Response, c *Ctx,
	run func(context.Context, *Ctx) (any, error)) api.Response {
	err := t.ledgerTx(ctx, func(tx *sql.Tx) error {
		return db.BeginTowerRequestTx(tx, c.requestID, c.command, c.Now())
	})
	if errors.Is(err, db.ErrTowerRequestExists) {
		// A duplicate began first and is acting now.
		return unknown(resp)
	}
	if err != nil {
		return t.fail(resp, c.command, err)
	}
	out, err := run(ctx, c)
	var r *RefusalError
	if errors.As(err, &r) {
		// A refusal is a definite no-act: record it done, so a resend of
		// this id answers the same refusal instead of unknown.
		ref := api.Refusal{Code: r.Code, Sentence: r.Sentence}
		b, merr := json.Marshal(ref)
		if merr == nil {
			merr = t.ledgerTx(ctx, func(tx *sql.Tx) error {
				return db.RefuseTowerRequestTx(tx, c.requestID, c.command, string(b), c.Now())
			})
		}
		if merr != nil {
			// The begun row stays: a resend answers unknown and never acts.
			log.Printf("tower: %s refused, but its refusal was not recorded: %v", c.command, merr)
		}
		return refused(resp, r.Code, r.Sentence)
	}
	if err != nil {
		// It may have acted before it failed.
		log.Printf("tower: %s failed after it began: %v", c.command, err)
		return unknown(resp)
	}
	b, err := json.Marshal(out)
	if err != nil {
		log.Printf("tower: %s acted, but its response could not be marshalled: %v", c.command, err)
		return unknown(resp)
	}
	if err := t.ledgerTx(ctx, func(tx *sql.Tx) error {
		return db.FinishTowerRequestTx(tx, c.requestID, c.command, string(b), c.Now())
	}); err != nil {
		// It acted; a resend answers unknown rather than acting again.
		log.Printf("tower: %s acted, but its done row was not recorded: %v", c.command, err)
	}
	return ok(resp, b)
}

// storedResult answers the done row a concurrent duplicate committed.
func (t *Tower) storedResult(ctx context.Context, resp api.Response, c *Ctx) api.Response {
	row, err := t.db.GetTowerRequest(ctx, c.requestID)
	if err != nil {
		return t.fail(resp, c.command, err)
	}
	if row == nil || row.State != "done" {
		return t.fail(resp, c.command, fmt.Errorf("tower: the done row of %s is gone", c.command))
	}
	return t.storedAnswer(resp, c.command, row)
}

// storedAnswer answers a done row: its stored result, or its stored refusal.
func (t *Tower) storedAnswer(resp api.Response, command string, row *db.TowerRequest) api.Response {
	if row.RefusalJSON == "" {
		return ok(resp, json.RawMessage(row.ResultJSON))
	}
	var r api.Refusal
	if err := json.Unmarshal([]byte(row.RefusalJSON), &r); err != nil {
		return t.fail(resp, command, fmt.Errorf("tower: read the stored refusal of %s: %w", command, err))
	}
	return refused(resp, r.Code, r.Sentence)
}

// ledgerTx runs fn in one short write transaction.
func (t *Tower) ledgerTx(ctx context.Context, fn func(tx *sql.Tx) error) error {
	tx, err := t.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("tower: begin the ledger write: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if err := fn(tx); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("tower: commit the ledger write: %w", err)
	}
	return nil
}

// Write runs fn in one write transaction (BEGIN IMMEDIATE) and commits it.
// For a guarded command it writes the done ledger row with fn's marshalled
// result in the same transaction, so fn's result is the command's response,
// and a guarded command calls Write once. After the commit it calls
// Options.Changed with the command's ChangeTables. fn's error rolls the
// transaction back and is returned as is (a Refuse error refuses the call).
// Keep fn short: no network, LLM call or slow render inside it.
func (c *Ctx) Write(ctx context.Context, fn func(tx *sql.Tx) (any, error)) (any, error) {
	if c.guarded && c.stored != nil {
		return nil, fmt.Errorf("tower: %s is guarded and already wrote", c.command)
	}
	tx, err := c.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("tower: begin %s: %w", c.command, err)
	}
	defer func() { _ = tx.Rollback() }()
	res, err := fn(tx)
	if err != nil {
		return nil, err
	}
	var stored []byte
	if c.guarded {
		if stored, err = json.Marshal(res); err != nil {
			return nil, fmt.Errorf("tower: marshal the %s response: %w", c.command, err)
		}
		err = db.FinishTowerRequestTx(tx, c.requestID, c.command, string(stored), c.Now())
		if errors.Is(err, db.ErrTowerRequestExists) {
			_ = tx.Rollback()
			row, gerr := c.DB.GetTowerRequest(ctx, c.requestID)
			if gerr != nil {
				return nil, gerr
			}
			if row == nil {
				return nil, fmt.Errorf("tower: the done row of %s is gone", c.command)
			}
			c.stored = json.RawMessage(row.ResultJSON)
			return nil, errAlreadyDone
		}
		if err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("tower: commit %s: %w", c.command, err)
	}
	if c.guarded {
		c.stored = stored
	}
	if changed := c.tower.opts.Changed; changed != nil && len(c.spec.ChangeTables) > 0 {
		changed(c.spec.ChangeTables)
	}
	return res, nil
}
