package oauthpage

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/companybundle"
)

// stubOpenURL swaps openURL for the test so nothing ever launches the app.
func stubOpenURL(t *testing.T, fn func(context.Context, string) error) {
	t.Helper()
	prev := openURL
	openURL = fn
	t.Cleanup(func() { openURL = prev })
}

// The services every login flow passes to Success.
var services = []string{"Slack", "Jira", "Gmail", "Your Google account", "Outlook", "The MCP server"}

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
	// The reason stays on screen: no close attempt on a failure.
	assert.NotContains(t, page, "window.close()")
}

func TestError_EscapesOnce(t *testing.T) {
	assert.Contains(t, Error("a&b", false), "<p>a&amp;b</p>")
	assert.Contains(t, Success("R&D", false), "<p>R&amp;D is connected")
}

func TestError_EmptyReason(t *testing.T) {
	page := Error("", false)
	assert.Contains(t, page, "Authorization failed")
	assert.Contains(t, page, "<p></p>")
}

func TestStale_NoCloseNoAppReturn(t *testing.T) {
	page := Stale()
	assert.Contains(t, page, "This sign-in page is out of date")
	assert.NotContains(t, page, "window.close")
	assert.NotContains(t, page, appReturnURL)
}

func TestReturnAfterLogin_OpensAppURL(t *testing.T) {
	// Success and a failed sign-in alike: the owner sees the outcome in the app.
	for _, loginErr := range []error{nil, errors.New("slack authorization denied: access_denied")} {
		var got []string
		stubOpenURL(t, func(_ context.Context, u string) error { got = append(got, u); return nil })

		var warn bytes.Buffer
		ReturnAfterLogin(true, loginErr, &warn)
		assert.Equal(t, []string{appReturnURL}, got, "loginErr=%v", loginErr)
		assert.Empty(t, warn.String())
	}
}

func TestReturnAfterLogin_SkipsWithoutAppReturn(t *testing.T) {
	called := false
	stubOpenURL(t, func(context.Context, string) error { called = true; return nil })

	ReturnAfterLogin(false, nil, &bytes.Buffer{})
	assert.False(t, called, "a plain CLI login never touches the app")
}

func TestReturnAfterLogin_SkipsTimeoutAndCancel(t *testing.T) {
	called := false
	stubOpenURL(t, func(context.Context, string) error { called = true; return nil })

	for _, loginErr := range []error{
		fmt.Errorf("%w after %s", ErrLoginTimedOut, "5m0s"),
		fmt.Errorf("oauth login: %w", fmt.Errorf("%w after %s", ErrLoginTimedOut, "5m0s")),
		fmt.Errorf("mcpoauth: %w or was cancelled: %w", ErrLoginTimedOut, context.DeadlineExceeded),
	} {
		ReturnAfterLogin(true, loginErr, &bytes.Buffer{})
		assert.False(t, called, "nobody is at the browser after %v — no focus steal", loginErr)
	}
}

func TestReturnAfterLogin_ExchangeDeadlineStillReturns(t *testing.T) {
	called := false
	stubOpenURL(t, func(context.Context, string) error { called = true; return nil })

	// The callback arrived, then the exchange ran into the deadline: the owner
	// has just been in the browser, so the app comes back with the error.
	ReturnAfterLogin(true, fmt.Errorf("exchanging code for token: %w", context.DeadlineExceeded), &bytes.Buffer{})
	assert.True(t, called)
}

func TestReturnAfterLogin_OpenFailureWarns(t *testing.T) {
	stubOpenURL(t, func(context.Context, string) error { return errors.New("boom") })

	var warn bytes.Buffer
	ReturnAfterLogin(true, nil, &warn)
	assert.Contains(t, warn.String(), "could not bring Watchtower to the front: boom")
}

func TestReturnAfterLogin_BoundedOpen(t *testing.T) {
	var hasDeadline bool
	stubOpenURL(t, func(ctx context.Context, _ string) error { _, hasDeadline = ctx.Deadline(); return nil })

	ReturnAfterLogin(true, nil, &bytes.Buffer{})
	assert.True(t, hasDeadline, "a hung open must not hold the CLI's exit")
}

func TestSetOpenURLForTest_Restores(t *testing.T) {
	var got string
	restore := SetOpenURLForTest(func(u string) error { got = u; return nil })
	ReturnAfterLogin(true, nil, &bytes.Buffer{})
	restore()
	assert.Equal(t, appReturnURL, got)

	called := false
	stubOpenURL(t, func(context.Context, string) error { called = true; return nil })
	restore2 := SetOpenURLForTest(func(string) error { return nil })
	restore2()
	ReturnAfterLogin(true, nil, &bytes.Buffer{})
	assert.True(t, called, "restore puts the previous opener back")
}

func TestSwitchToApp_AsksForTheAppAndLinksNowhere(t *testing.T) {
	page := SwitchToApp()
	assert.Contains(t, page, "Switch to Watchtower to confirm")
	assert.NotContains(t, page, "href=")
	assert.NotContains(t, page, "window.close")
}

func TestCheckApp_PointsToTheApp(t *testing.T) {
	page := CheckApp()
	assert.Contains(t, page, "Check Watchtower for the result")
	assert.NotContains(t, page, "href=")
	assert.NotContains(t, page, "window.close")
}

func TestCompanyPages_Open(t *testing.T) {
	page := CompanyOpen("Acme")
	assert.Contains(t, page, "<h1>Continue in Watchtower</h1>")
	assert.Contains(t, page, "<p>Watchtower is asking you to confirm Acme. You can close this tab.</p>")
	assert.NotContains(t, page, "window.close", "nothing is connected yet; the tab stays")
	assert.NotContains(t, page, "href=")

	hostile := CompanyOpen(`<script>alert(1)</script>`)
	assert.NotContains(t, hostile, "<script>alert(1)</script>", "the company name is escaped")
}

func TestCompanyPages_RefusedPerReason(t *testing.T) {
	want := map[companybundle.Refusal]string{
		companybundle.RefusalDamaged:      "The link is damaged or cut short.",
		companybundle.RefusalTooLong:      "The link is too long to be a Watchtower company link.",
		companybundle.RefusalSiteNotHTTPS: "The link names a site that is not https.",
		companybundle.RefusalPersonal:     "The link carries a personal Google project, which only this Mac can set.",
	}
	assert.Equal(t, want, CompanyRefusedReasons)
	for reason, line := range want {
		page := CompanyRefused(reason)
		assert.Contains(t, page, "<h1>This link does not work</h1>", reason)
		assert.Contains(t, page, "<p>"+line+"</p>", reason)
		assert.Contains(t, page,
			"Ask your admin for a fresh link, or paste the connect code in Watchtower → Connections.", reason)
	}
	assert.Contains(t, CompanyRefused("something_new"), "<p>The link is damaged or cut short.</p>",
		"a reason without a line reads as damaged")
}

func TestCompanyPages_NeedsNewer(t *testing.T) {
	page := CompanyNeedsNewer()
	assert.Contains(t, page, "<h1>This link needs a newer Watchtower</h1>")
	assert.Contains(t, page, "<p>Update Watchtower from its menu, then open the link again.</p>")
	assert.Equal(t, page, CompanyRefused(companybundle.RefusalNewerVersion))
}

func TestCompanyPages_Busy(t *testing.T) {
	page := CompanyBusy()
	assert.Contains(t, page, "<h1>"+CompanyBusyHeading+"</h1>")
	assert.Contains(t, page, "<p>"+CompanyBusyMessage+"</p>")
	assert.Contains(t, page, "You can close this tab.")
}

func TestCompanyPages_NotTaken(t *testing.T) {
	page := CompanyNotTaken()
	assert.Contains(t, page, "<h1>Watchtower did not take this link</h1>")
	assert.Contains(t, page, "<p>Open Watchtower, then open the link again.</p>")
}
