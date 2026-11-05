package chat

import (
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/providers"
)

// providerCategories are the ErrorCategory constants declared in
// internal/providers/failure.go, read from the source so a category added
// there without a row in failureCodes fails TestCodeForFailure_EveryCategory.
func providerCategories(t *testing.T) []providers.ErrorCategory {
	t.Helper()
	f, err := parser.ParseFile(token.NewFileSet(), "../providers/failure.go", nil, 0)
	require.NoError(t, err)
	var out []providers.ErrorCategory
	for _, decl := range f.Decls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok || gen.Tok != token.CONST {
			continue
		}
		for _, spec := range gen.Specs {
			vs := spec.(*ast.ValueSpec)
			if id, ok := vs.Type.(*ast.Ident); !ok || id.Name != "ErrorCategory" {
				continue
			}
			for i := range vs.Names {
				lit := vs.Values[i].(*ast.BasicLit)
				out = append(out, providers.ErrorCategory(lit.Value[1:len(lit.Value)-1]))
			}
		}
	}
	require.NotEmpty(t, out, "no ErrorCategory constants found")
	return out
}

// TestCodeForFailure_EveryCategory: every providers category has exactly one
// chat code (one row), and the code is one the protocol declares.
func TestCodeForFailure_EveryCategory(t *testing.T) {
	known := map[string]bool{CodeAuth: true, CodeRateLimit: true, CodeProviderUnavailable: true, CodeSessionLost: true,
		CodeAttachmentUnsupported: true, CodeInterrupted: true, CodeInternal: true}
	cats := providerCategories(t)
	for _, c := range cats {
		row, ok := failureCodes[c]
		if !assert.True(t, ok, "category %q has no row in failureCodes", c) {
			continue
		}
		assert.True(t, known[row.code], "category %q maps to an undeclared code %q", c, row.code)
		code, retry := CodeForFailure(c)
		assert.Equal(t, row.code, code)
		assert.Equal(t, row.retryable, retry)
	}
	assert.Len(t, failureCodes, len(cats), "failureCodes has a row for a category providers does not declare")

	code, retry := CodeForFailure(providers.Quota)
	assert.Equal(t, CodeRateLimit, code)
	assert.False(t, retry, "a spent subscription does not come back on a retry")
	code, _ = CodeForFailure(providers.Auth)
	assert.Equal(t, CodeAuth, code)
	code, retry = CodeForFailure(providers.Cancelled)
	assert.Equal(t, CodeInterrupted, code)
	assert.False(t, retry)
}

// ClassifyFailure reads a typed failure first; only an untyped error (or one
// typed Unknown) falls back to the Claude text matcher.
func TestClassifyFailure_TypedFirstThenText(t *testing.T) {
	quota := &providers.Failure{Provider: "codex", Category: providers.Quota, Cause: errors.New("authentication_error: you are not logged in")}
	code, reason, retry := ClassifyFailure(quota)
	assert.Equal(t, CodeRateLimit, code)
	assert.Equal(t, "quota_exhausted", reason)
	assert.False(t, retry)

	capErr := providers.CapabilityError("ollama", providers.ReviewReadonly, errors.New("no file tools"))
	code, reason, retry = ClassifyFailure(capErr)
	assert.Equal(t, CodeInternal, code)
	assert.Equal(t, "required_capability_missing", reason)
	assert.False(t, retry)

	code, reason, _ = ClassifyFailure(errors.New("429 Too Many Requests"))
	assert.Equal(t, CodeRateLimit, code, "an untyped error keeps the text matcher")
	assert.Empty(t, reason)

	code, _, _ = ClassifyFailure(providers.WithFailure("ollama", providers.Unknown, errors.New("Not logged in · please run /login")))
	assert.Equal(t, CodeAuth, code, "an Unknown failure still gets the text matcher")
}

// TestTurnBackend_TypedFailureWinsOverText: a codex quota Failure whose text
// says "authentication" still ends the turn with the quota code and reason.
func TestTurnBackend_TypedFailureWinsOverText(t *testing.T) {
	d, conv := seedConversation(t)
	fq := &fakeQuerier{err: &providers.Failure{Provider: "codex", Category: providers.Quota,
		Cause: errors.New("authentication_error: 401 not logged in")}}
	h := startSession(t, NewTurnBackend(fq, d, conv), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "why?"})
	e := h.next(EventError)
	assert.Equal(t, CodeRateLimit, e.Code, "quota_exhausted's code, not auth from the text")
	assert.Equal(t, "quota_exhausted", e.Reason)
	assert.False(t, e.Retryable)
	require.NoError(t, h.finish())
}
