// Package oauthpage renders the page every loopback OAuth callback serves
// (Slack, Jira, Google, Gmail, Outlook, MCP connections) and brings the
// desktop app back to the front once a Desktop-started sign-in is done.
//
// The pages never promise that the tab closes itself: browsers only let a
// script close a tab a script opened, and these tabs are opened by `open URL`
// (or by the provider's redirect), so the success page's window.close() is
// best effort. The page says so plainly and, for a Desktop-started sign-in,
// offers a "Back to Watchtower" link to the watchtower-auth:// scheme. That
// link is a user gesture, so browsers honour it; the automatic return is
// ReturnAfterLogin, run by the CLI, not a scripted redirect (which browsers
// block or turn into a permission prompt).
package oauthpage

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"html/template"
	"io"
	"os/exec"
	"runtime"
	"strings"
	"time"
)

// appReturnURL is the custom scheme the desktop app registers
// (CFBundleURLSchemes in scripts/build-app.sh); opening it brings the app to
// the front.
const appReturnURL = "watchtower-auth://connected"

// closeAttemptMS is when the success page tries window.close(). Late enough
// to read the page if a browser does allow it.
const closeAttemptMS = "3000"

// ErrLoginTimedOut is what every loopback Login wraps when its wait for the
// callback ends (timeout, or the login was cancelled) — ReturnAfterLogin does not pull the app forward for it.
var ErrLoginTimedOut = errors.New("login timed out")

// Success renders the page served when the provider redirected back with a
// code. service names what was connected ("Slack", "Jira", "Your Google
// account"); appReturn adds the "Back to Watchtower" link (set when the
// Desktop started the sign-in with --app-return).
func Success(service string, appReturn bool) string {
	return render(page{
		Title:      "Connected",
		IconClass:  "icon-ok",
		Icon:       "✓",
		Heading:    "Connected",
		Message:    service + " is connected to Watchtower. You can close this tab.",
		AppReturn:  appReturn,
		TryToClose: true,
	})
}

// Error renders the page served when the provider redirected back with an
// error (and, for the MCP flow, when the code exchange failed). reason is
// shown escaped. The tab never tries to close itself, so the reason stays
// readable.
func Error(reason string, appReturn bool) string {
	return render(page{
		Title:     "Authorization failed",
		IconClass: "icon-err",
		Icon:      "✕",
		Heading:   "Authorization failed",
		Message:   reason,
		Hint:      "You can close this tab and try again in Watchtower.",
		AppReturn: appReturn,
	})
}

type page struct {
	Title, IconClass, Icon, Heading, Message, Hint string
	AppReturn, TryToClose                          bool
}

// pageTemplate is html/template, so every field — Message carries the
// provider's error text or a service name — is escaped on output.
var pageTemplate = template.Must(template.New("page").Parse(`<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Watchtower — {{.Title}}</title>` + style + `</head><body>
<div class="card">
<div class="icon {{.IconClass}}">{{.Icon}}</div>
<h1>{{.Heading}}</h1>
<p>{{.Message}}</p>
{{if .AppReturn}}<a class="btn" href="` + appReturnURL + `">Back to Watchtower</a>
{{end}}{{if .Hint}}<div class="hint">{{.Hint}}</div>
{{end}}</div>
{{if .TryToClose}}<script>setTimeout(function(){try{window.close()}catch(e){}},` + closeAttemptMS + `);</script>
{{end}}</body></html>`))

func render(p page) string {
	var b strings.Builder
	// Execute only fails on a template/data mismatch, which the tests over
	// every page shape would catch.
	if err := pageTemplate.Execute(&b, p); err != nil {
		panic(fmt.Sprintf("oauthpage: rendering %q: %v", p.Title, err))
	}
	return b.String()
}

const style = `<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
background:#0f0f0f;color:#e5e5e5;display:flex;align-items:center;justify-content:center;
min-height:100vh;padding:20px}
.card{background:#1a1a1a;border:1px solid #2a2a2a;border-radius:16px;padding:48px;
max-width:440px;width:100%;text-align:center;box-shadow:0 4px 24px rgba(0,0,0,.4)}
.icon{width:64px;height:64px;margin:0 auto 24px;border-radius:50%;display:flex;
align-items:center;justify-content:center;font-size:32px}
.icon-ok{background:#0d2818;border:2px solid #16a34a}
.icon-err{background:#2d0f0f;border:2px solid #dc2626}
h1{font-size:20px;font-weight:600;margin-bottom:8px}
p{font-size:14px;color:#888;line-height:1.5;margin-bottom:24px}
.btn{display:inline-block;background:#fff;color:#0f0f0f;font-size:14px;font-weight:600;
padding:12px 32px;border-radius:10px;text-decoration:none;cursor:pointer;border:none;
transition:opacity .15s}
.btn:hover{opacity:.85}
.hint{font-size:12px;color:#555;margin-top:16px}
</style>`

// openURL hands a URL to LaunchServices. A var so tests never launch the app.
var openURL = func(ctx context.Context, u string) error {
	if runtime.GOOS != "darwin" {
		return nil
	}
	out, err := exec.CommandContext(ctx, "/usr/bin/open", u).CombinedOutput()
	if err != nil {
		return fmt.Errorf("open %s: %w: %s", u, err, bytes.TrimSpace(out))
	}
	return nil
}

// SetOpenURLForTest swaps what ReturnAfterLogin runs to open the app URL, so
// a test of a login command never launches the real app.
func SetOpenURLForTest(fn func(u string) error) (restore func()) {
	prev := openURL
	openURL = func(_ context.Context, u string) error { return fn(u) }
	return func() { openURL = prev }
}

// ReturnAfterLogin is what a CLI login command runs once its OAuth flow has
// returned, successfully or not: with appReturn (the Desktop started the
// sign-in) it opens watchtower-auth:// through LaunchServices, so the app
// comes back to the front and the owner sees the outcome there. The browser
// cannot be relied on to follow a scripted redirect to a custom scheme, so
// this is the automatic half of app-return. Skipped when the wait for the
// callback ran out (loginErr wraps ErrLoginTimedOut): nobody is at the
// browser then, and pulling the app forward minutes later would only steal
// focus. A failure after the callback (a slow exchange hitting the
// deadline included) still brings the app back. A failure to open
// the app only warns: the sign-in itself is unaffected and the page still
// has the link.
func ReturnAfterLogin(appReturn bool, loginErr error, warn io.Writer) {
	if !appReturn || errors.Is(loginErr, ErrLoginTimedOut) {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := openURL(ctx, appReturnURL); err != nil {
		fmt.Fprintf(warn, "warning: could not bring Watchtower to the front: %v\n", err)
	}
}
