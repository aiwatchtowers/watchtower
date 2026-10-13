package oauthpage

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

// stubOpenURL swaps openURL for the test so nothing ever launches the app.
func stubOpenURL(t *testing.T, fn func(context.Context, string) error) {
	t.Helper()
	prev := openURL
	openURL = fn
	t.Cleanup(func() { openURL = prev })
}

// The services every login flow passes to Success.
var services = []string{"Slack", "Jira", "Gmail", "Your Google account", "Outlook", "This connection"}

func TestSuccess_HonestCloseText(t *testing.T) {
	for _, svc := range services {
		for _, appReturn := range []bool{true, false} {
			page := Success(svc, appReturn)
			assert.Contains(t, page, svc+" is connected to Watchtower. You can close this tab.")
			// Never promise the tab closes itself: browsers refuse
			// window.close() on a tab no script opened.
			lower := strings.ToLower(page)
			for _, promise := range []string{"will close", "closes automatically", "close automatically", "closing"} {
				assert.NotContains(t, lower, promise, "%s appReturn=%v", svc, appReturn)
			}
			// Still tried, best effort.
			assert.Contains(t, page, "window.close()")
		}
	}
}

func TestSuccess_AppReturnLink(t *testing.T) {
	page := Success("Slack", true)
	assert.Contains(t, page, `<a class="btn" href="watchtower-auth://connected">Back to Watchtower</a>`)
	// No scripted redirect to the scheme: the CLI brings the app back, and a
	// scripted one only turns into a browser permission prompt.
	assert.NotContains(t, page, "location.href")

	plain := Success("Slack", false)
	assert.NotContains(t, plain, "watchtower-auth://", "a plain CLI login has no app to return to")
}

func TestSuccess_EscapesService(t *testing.T) {
	page := Success(`<b>x</b>`, false)
	assert.Contains(t, page, "&lt;b&gt;x&lt;/b&gt;")
	assert.NotContains(t, page, "<b>x</b>")
}

func TestError_EscapesReasonAndLinksBack(t *testing.T) {
	page := Error(`<script>alert(1)</script>`, true)
	assert.Contains(t, page, "Authorization failed")
	assert.Contains(t, page, "&lt;script&gt;alert(1)&lt;/script&gt;")
	assert.NotContains(t, page, "<script>alert(1)</script>")
	assert.Contains(t, page, "You can close this tab and try again in Watchtower.")
	assert.Contains(t, page, `href="watchtower-auth://connected">Back to Watchtower</a>`)

	assert.NotContains(t, Error("access_denied", false), "watchtower-auth://")
}

func TestError_EmptyReason(t *testing.T) {
	page := Error("", false)
	assert.Contains(t, page, "Authorization failed")
	assert.Contains(t, page, "<p></p>")
}

func TestReturnAfterLogin_OpensAppURL(t *testing.T) {
	var got []string
	stubOpenURL(t, func(_ context.Context, u string) error { got = append(got, u); return nil })

	var warn bytes.Buffer
	ReturnAfterLogin(context.Background(), true, &warn)
	assert.Equal(t, []string{AppReturnURL}, got)
	assert.Empty(t, warn.String())
}

func TestReturnAfterLogin_SkipsWithoutAppReturn(t *testing.T) {
	called := false
	stubOpenURL(t, func(context.Context, string) error { called = true; return nil })

	ReturnAfterLogin(context.Background(), false, &bytes.Buffer{})
	assert.False(t, called, "a plain CLI login never touches the app")
}

func TestReturnAfterLogin_SkipsWhenCancelled(t *testing.T) {
	called := false
	stubOpenURL(t, func(context.Context, string) error { called = true; return nil })

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	ReturnAfterLogin(ctx, true, &bytes.Buffer{})
	assert.False(t, called, "a cancelled sign-in was cancelled from the app — the owner is there already")
}

func TestReturnAfterLogin_NilContext(t *testing.T) {
	called := false
	stubOpenURL(t, func(context.Context, string) error { called = true; return nil })

	//nolint:staticcheck // a command run without a context hands back nil
	ReturnAfterLogin(nil, true, &bytes.Buffer{})
	assert.True(t, called)
}

func TestReturnAfterLogin_OpenFailureWarns(t *testing.T) {
	stubOpenURL(t, func(context.Context, string) error { return errors.New("boom") })

	var warn bytes.Buffer
	ReturnAfterLogin(context.Background(), true, &warn)
	assert.Contains(t, warn.String(), "could not bring Watchtower to the front: boom")
}
