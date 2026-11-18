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

// LabelItem is one decision the labeller looks at. NeedCategory is set when
// the source could not place it in a category; otherwise only its flags are
// read (spec §9.1: a category Go set is never replaced).
type LabelItem struct {
	Situation, Choice string
	NeedCategory      bool
}

// Label is the labeller's answer for one item. A Category that is not one
// of the eight means "no category"; a nil flag means the reply did not give
// it (spec §9.1 Failures: retried once, then left unset).
type Label struct {
	Category         string
	Decision, Parked *bool
}

// Labeler returns one Label per item, in order. An error means nothing was
// labelled (the batch is tried again).
type Labeler interface {
	Label(ctx context.Context, items []LabelItem) ([]Label, error)
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

func (l llmLabeler) Label(ctx context.Context, items []LabelItem) ([]Label, error) {
	out := make([]Label, 0, len(items))
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
	Situation    string `json:"situation"`
	Choice       string `json:"choice"`
	NeedCategory bool   `json:"need_category"`
}

type labelReplyItem struct {
	Category *string `json:"category"`
	Decision *bool   `json:"decision"`
	Parked   *bool   `json:"parked"`
}

// labelBatch asks the model once. A reply that is not a JSON array of
// objects, or whose array has the wrong length, cannot be lined up with the
// items: every item of the batch comes back empty (Label{}) rather than risk
// a shifted label inflating a category or stalling the source. Only a
// generator error is an error (retried next cycle).
func (l llmLabeler) labelBatch(ctx context.Context, items []LabelItem) ([]Label, error) {
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
	out := make([]Label, len(items))
	var labels []labelReplyItem
	if err := json.Unmarshal([]byte(trimJSONFence(strings.TrimSpace(raw))), &labels); err != nil {
		// A reply that is not a JSON array of objects (the v1 array of
		// strings included) is the model's answer, not an outage: like a
		// wrong length, the batch comes back unlabelled so the source moves
		// on instead of re-paying it every cycle. The reply may quote an
		// item: only its fingerprint is logged.
		log.Printf("watchman label: %v", logredact.Errorf("the reply is not a JSON array of objects, %d items left unlabelled: %s",
			len(items), logredact.Text(err.Error())))
		return out, nil //nolint:nilerr // an unparseable reply is an answer: the batch is unlabelled, not retried
	}
	if len(labels) == len(items) {
		for i, r := range labels {
			if r.Category != nil {
				out[i].Category = strings.TrimSpace(*r.Category)
			}
			out[i].Decision, out[i].Parked = r.Decision, r.Parked
		}
	}
	return out, nil
}
