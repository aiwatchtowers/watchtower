package ideas

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"
)

type extractionWindowKey struct{}

// prepareExtraction binds one primitive pass, not a recipe or a source fetch.
// Backfill keys include both bounds and the input floor. Replaying the drain
// follows completed prefixes without repeating saved (even empty) model calls.
func (p *Pipeline) prepareExtraction(ctx context.Context, source string, account int64, floor string, bound time.Time) (context.Context, time.Time, *db.IdeasExtractionWindow, error) {
	if !digest.RoutingEnabled(p.generator, ctx) {
		return ctx, bound, nil, nil
	}
	key := "forward"
	if !bound.IsZero() {
		key = "backfill:" + floor + ":" + bound.UTC().Format(time.RFC3339Nano)
	} else {
		bound = time.Now().UTC()
	}
	w, err := p.db.ClaimIdeasExtractionWindow(db.IdeasExtractionWindow{Source: source, AccountID: account, Key: key, From: floor, To: bound.UTC().Format(time.RFC3339Nano)})
	if err != nil {
		return ctx, bound, nil, fmt.Errorf("claiming extraction window: %w", err)
	}
	bound, err = time.Parse(time.RFC3339Nano, w.To)
	if err != nil {
		return ctx, bound, nil, err
	}
	return context.WithValue(ctx, extractionWindowKey{}, w), bound, &w, nil
}

func (p *Pipeline) commitExtraction(ctx context.Context, row db.StreamDigest, topics []streamTopic, what, reached string) error {
	w, ok := ctx.Value(extractionWindowKey{}).(db.IdeasExtractionWindow)
	if !ok {
		return p.insertStreamTopics(row, topics, what)
	}
	w.Reached, w.Complete = reached, true
	var output *db.StreamDigest
	if len(topics) > 0 {
		data, err := json.Marshal(topics)
		if err != nil {
			return err
		}
		row.TopicsJSON = string(data)
		output = &row
	}
	return p.db.CommitIdeasExtraction(w, output)
}

func (p *Pipeline) completeEmptyExtraction(ctx context.Context, floor string) error {
	w, ok := ctx.Value(extractionWindowKey{}).(db.IdeasExtractionWindow)
	if !ok {
		return nil
	}
	w.Reached, w.Complete = floor, true
	return p.db.CommitIdeasExtraction(w, nil)
}

func emailExtractionFloor(w *db.IdeasExtractionWindow, floor float64) (float64, error) {
	if w == nil {
		return floor, nil
	}
	value := w.From
	if w.Complete {
		value = w.Reached
	}
	return strconv.ParseFloat(value, 64)
}

// backfillExtractionStart keeps the original effective lower floor when a
// partial drain raises a live floor across the chunk's starting boundary.
func (p *Pipeline) backfillExtractionStart(source string, account int64, from, to time.Time, floor string, ctx context.Context) (string, error) {
	if !digest.RoutingEnabled(p.generator, ctx) {
		return floor, nil
	}
	w, err := p.db.ClaimIdeasExtractionWindow(db.IdeasExtractionWindow{Source: source, AccountID: account, Key: "chunk:" + from.UTC().Format(time.RFC3339Nano) + ":" + to.UTC().Format(time.RFC3339Nano), From: floor, To: to.UTC().Format(time.RFC3339Nano)})
	return w.From, err
}
