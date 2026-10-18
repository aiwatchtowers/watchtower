package cmd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/jira"
	"watchtower/internal/oauthpage"
)

// scriptLogin swaps jiraLogin for answers (one per call) and records the
// options of every call.
func scriptLogin(t *testing.T, answers ...error) *[]jira.LoginOptions {
	t.Helper()
	var calls []jira.LoginOptions
	orig := jiraLogin
	jiraLogin = func(_ context.Context, _ jira.JiraOAuthConfig, _ io.Writer, opts ...jira.LoginOptions) (*jira.OAuthToken, error) {
		calls = append(calls, opts[0])
		err := answers[len(calls)-1]
		if err != nil {
			return nil, err
		}
		return &jira.OAuthToken{AccessToken: "a"}, nil
	}
	t.Cleanup(func() { jiraLogin = orig })
	return &calls
}

var errTestScopeRefused = fmt.Errorf("jira authorization denied: invalid_scope: %w", jira.ErrScopeRefused)

// TestJiraAddLogin_ScopeRefusalRetriesJiraOnly (#573): an app without the
// Confluence API refuses the wider scopes; the connect retries once with
// the Jira scopes alone instead of failing.
func TestJiraAddLogin_ScopeRefusalRetriesJiraOnly(t *testing.T) {
	calls := scriptLogin(t, errTestScopeRefused, nil)
	var out bytes.Buffer
	token, err := jiraAddLogin(context.Background(), jira.JiraOAuthConfig{}, &out, jira.LoginOptions{WithConfluence: true, AppReturn: true})
	require.NoError(t, err)
	require.NotNil(t, token)
	require.Len(t, *calls, 2)
	assert.True(t, (*calls)[0].WithConfluence)
	assert.False(t, (*calls)[1].WithConfluence, "the retry asks for Jira only")
	assert.True(t, (*calls)[1].AppReturn, "the retry keeps the other options")
	assert.Contains(t, out.String(), "connecting Jira only")
	// The Desktop keys its "second sign-in tab" status on this token.
	assert.Contains(t, out.String(), "[jira-only-retry]")
}

// A login nobody completes exits with the stable timeout code the Desktop
// reads; any other failure stays exit 1.
func TestJiraAddLoginError_TimeoutHasItsOwnExitCode(t *testing.T) {
	err := jiraAddLoginError(fmt.Errorf("%w after 5m0s", oauthpage.ErrLoginTimedOut))
	var ec *exitCodeError
	require.ErrorAs(t, err, &ec)
	assert.Equal(t, 75, ec.code)
	assert.ErrorIs(t, err, oauthpage.ErrLoginTimedOut)

	err = jiraAddLoginError(errors.New("jira authorization denied: access_denied"))
	assert.False(t, errors.As(err, &ec))
}

func TestJiraAddLogin_RetriesOnlyOnce(t *testing.T) {
	calls := scriptLogin(t, errTestScopeRefused, errTestScopeRefused)
	_, err := jiraAddLogin(context.Background(), jira.JiraOAuthConfig{}, io.Discard, jira.LoginOptions{WithConfluence: true})
	require.ErrorIs(t, err, jira.ErrScopeRefused)
	assert.Len(t, *calls, 2)
}

// Any other failure, or a refusal of a Jira-only consent, is not retried.
func TestJiraAddLogin_NoRetryOtherwise(t *testing.T) {
	calls := scriptLogin(t, errors.New("jira authorization denied: access_denied"))
	_, err := jiraAddLogin(context.Background(), jira.JiraOAuthConfig{}, io.Discard, jira.LoginOptions{WithConfluence: true})
	require.Error(t, err)
	assert.Len(t, *calls, 1)

	calls = scriptLogin(t, errTestScopeRefused)
	_, err = jiraAddLogin(context.Background(), jira.JiraOAuthConfig{}, io.Discard, jira.LoginOptions{})
	require.ErrorIs(t, err, jira.ErrScopeRefused)
	assert.Len(t, *calls, 1)
}
