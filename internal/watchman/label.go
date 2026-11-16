package watchman

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strings"

	"watchtower/internal/digest"
	"watchtower/internal/logredact"
	"watchtower/internal/prompts"
)

// labelBatch is how many items one model call labels.
const labelBatch = 20

// LabelItem is one decision a source could not place in a category.
type LabelItem struct {
	Situation, Choice string
}

// Labeler returns one category per item, in order. A returned category that
// is not one of the eight means "no label": the runner does not store that
// item. An error means nothing was labelled (the batch is tried again).
type Labeler interface {
	Label(ctx context.Context, items []LabelItem) ([]string, error)
}

// NewLLMLabeler labels on the light tier (prompts.WatchmanLabel), labelBatch
// items per call.
func NewLLMLabeler(gen digest.Generator, store *prompts.Store) Labeler {
	return llmLabeler{gen: gen, store: store}
}

type llmLabeler struct {
	gen   digest.Generator
	store *prompts.Store
}

func (l llmLabeler) Label(ctx context.Context, items []LabelItem) ([]string, error) {
	out := make([]string, 0, len(items))
	for start := 0; start < len(items); start += labelBatch {
		got, err := l.labelBatch(ctx, items[start:min(start+labelBatch, len(items))])
		if err != nil {
			return nil, err
		}
		out = append(out, got...)
	}
	return out, nil
}

type labelInputItem struct {
	Situation string `json:"situation"`
	Choice    string `json:"choice"`
}

// labelBatch asks the model once. A reply that is not a JSON array, or whose
// array has the wrong length, cannot be lined up with the items: every item
// of the batch comes back unlabelled ("") rather than risk a shifted label
// inflating a category or stalling the source. Only a generator error is an
// error (retried next cycle).
func (l llmLabeler) labelBatch(ctx context.Context, items []LabelItem) ([]string, error) {
	in := struct {
		Items []labelInputItem `json:"items"`
	}{Items: make([]labelInputItem, len(items))}
	for i, it := range items {
		in.Items[i] = labelInputItem(it)
	}
	body, err := json.Marshal(in)
	if err != nil {
		return nil, fmt.Errorf("watchman label: encoding the items: %w", err)
	}
	// json.Marshal escapes '<' and '>', so no item text can close the fence.
	user := "=== DATA ===\n<data>\n" + string(body) + "\n</data>\n"
	// Known-safe ignore: on a failed or empty store read Resolve still hands
	// back the built-in template (the Decide precedent).
	tmpl, _, _ := prompts.Resolve(l.store, prompts.WatchmanLabel, "")
	raw, _, _, err := l.gen.Generate(digest.WithSource(ctx, prompts.WatchmanLabel), tmpl, user, "")
	if err != nil {
		return nil, fmt.Errorf("watchman label: generating: %w", err)
	}
	out := make([]string, len(items))
	var labels []string
	if err := json.Unmarshal([]byte(trimJSONFence(strings.TrimSpace(raw))), &labels); err != nil {
		// A reply that is not a JSON array is the model's answer, not an
		// outage: like a wrong length, the batch comes back unlabelled so
		// the source moves on instead of re-paying it every cycle. The
		// reply may quote an item: only its fingerprint is logged.
		log.Printf("watchman label: %v", logredact.Errorf("the reply is not a JSON array of strings, %d items left unlabelled: %s",
			len(items), logredact.Text(err.Error())))
		return out, nil //nolint:nilerr // an unparseable reply is an answer: the batch is unlabelled, not retried
	}
	if len(labels) == len(items) {
		for i, c := range labels {
			out[i] = strings.TrimSpace(c)
		}
	}
	return out, nil
}
