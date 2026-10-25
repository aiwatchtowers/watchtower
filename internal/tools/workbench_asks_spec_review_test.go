package tools

import (
	"errors"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

const specReviewAsk = `{"kind":"review","title":"Review","doc_path":%q,"reason":"r"}`

func TestAskOwner_SpecQueuesAndLaunches(t *testing.T) {
	fx := newWorkbenchFixture(t)
	var launched []int64
	reg := askRegistryWith(t, fx.d, "", func(id int64) error { launched = append(launched, id); return nil })
	writeWorkbenchFile(t, fx.d, fx.a, "docs/superpowers/specs/a-design.md", "# Spec\n")

	out := mustApply(t, reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, "docs/superpowers/specs/a-design.md"))
	id := askID(t, out)

	assert.Equal(t, "queued", out["spec_review"])
	assert.Equal(t, []int64{id}, launched)
	sr, err := fx.d.GetSpecReview(id)
	require.NoError(t, err)
	assert.Equal(t, "queued", sr.Status)
	assert.Equal(t, "spec", storedAsk(t, fx.d, fx.a, id).DocType)
}

func TestAskOwner_OtherDocNoReviewer(t *testing.T) {
	fx := newWorkbenchFixture(t)
	called := false
	reg := askRegistryWith(t, fx.d, "", func(int64) error { called = true; return nil })
	writeWorkbenchFile(t, fx.d, fx.a, "README.md", "# Readme\n")

	out := mustApply(t, reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, "README.md"))
	id := askID(t, out)

	assert.NotContains(t, out, "spec_review")
	assert.False(t, called)
	assert.Equal(t, "other", storedAsk(t, fx.d, fx.a, id).DocType)
	_, err := fx.d.GetSpecReview(id)
	assert.ErrorIs(t, err, db.ErrSpecReviewNotFound)
}

// SPECREVIEW-02: a reviewer that cannot start never blocks the owner's ask.
func TestSpecReview02_AskOwnerLaunchFailureStillFiles(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistryWith(t, fx.d, "", func(int64) error { return errors.New("no exec") })
	writeWorkbenchFile(t, fx.d, fx.a, "docs/plans/p.md", "# Plan\n")

	out := mustApply(t, reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, "docs/plans/p.md"))
	id := askID(t, out)

	assert.Equal(t, "skipped: launch failed: no exec", out["spec_review"])
	assert.Equal(t, "open", storedAsk(t, fx.d, fx.a, id).Status)
	sr, err := fx.d.GetSpecReview(id)
	require.NoError(t, err)
	assert.Equal(t, "skipped", sr.Status)
}

func TestAskOwner_LauncherSkipRecordedVerbatim(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistryWith(t, fx.d, "", func(int64) error { return ErrSpecReviewSkipped{Reason: "plan near limit"} })
	writeWorkbenchFile(t, fx.d, fx.a, "docs/plans/p.md", "# Plan\n")

	out := mustApply(t, reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, "docs/plans/p.md"))

	assert.Equal(t, "skipped: plan near limit", out["spec_review"])
}

func TestAskOwner_NilLauncherSkips(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	writeWorkbenchFile(t, fx.d, fx.a, "docs/plans/p.md", "# Plan\n")

	out := mustApply(t, reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, "docs/plans/p.md"))

	assert.Equal(t, "skipped: no reviewer on this surface", out["spec_review"])
}

func TestAskOwner_DocTypeOnlyOnReview(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	_, err := proposeIn(t, reg, fx.a, "ask_owner", `{"kind":"question","title":"x","doc_type":"spec",`+
		`"questions":[{"question":"q","options":[{"label":"a"},{"label":"b"}]}],"reason":"r"}`)
	assert.Contains(t, refusal(t, err), "doc_type")
}

func TestAskOwner_UnknownDocTypeRefused(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	writeWorkbenchFile(t, fx.d, fx.a, "docs/plans/p.md", "# Plan\n")
	_, err := proposeIn(t, reg, fx.a, "ask_owner", `{"kind":"review","title":"x","doc_path":"docs/plans/p.md","doc_type":"memo","reason":"r"}`)
	assert.Contains(t, refusal(t, err), "doc_type")
}

func TestAskOwner_LauncherSkipPointerRecordedVerbatim(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistryWith(t, fx.d, "", func(int64) error { return fmt.Errorf("wrapped: %w", &ErrSpecReviewSkipped{Reason: "plan near limit"}) })
	writeWorkbenchFile(t, fx.d, fx.a, "docs/plans/p.md", "# Plan\n")
	out := mustApply(t, reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, "docs/plans/p.md"))
	assert.Equal(t, "skipped: plan near limit", out["spec_review"])
}
