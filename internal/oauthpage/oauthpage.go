// Package oauthpage renders the page every loopback OAuth callback serves
// (Slack, Jira, Google, Gmail, Outlook, MCP connections) and brings the
// desktop app back to the front once a Desktop-started sign-in is done.
//
// The pages never promise that the tab closes itself: browsers only let a
// script close a tab a script opened, and these tabs are opened by `open URL`
// (or by the provider's redirect), so window.close() is attempted but is a
// no-op in practice. The page says so plainly and, for a Desktop-started
// sign-in, offers a "Back to Watchtower" link to the watchtower-auth://
// scheme. That link is a user gesture, so browsers honour it; the automatic
// return is ReturnToApp, run by the CLI, not a scripted redirect (which
// browsers block or turn into a permission prompt).
package oauthpage

import (
	"context"
	"fmt"
	"html"
	"io"
	"os/exec"
	"runtime"
	"strings"
	"time"
)

// AppReturnURL is the custom scheme the desktop app registers
// (CFBundleURLSchemes in scripts/build-app.sh); opening it brings the app to
// the front.
const AppReturnURL = "watchtower-auth://connected"

// closeAttemptMS is when the page tries window.close(). Late enough to read
// the page if a browser does allow it.
const closeAttemptMS = "3000"

// Success renders the page served after the provider redirected back with a
// code. service names what was connected ("Slack", "Jira", "your Google
// account"); appReturn adds the "Back to Watchtower" link (set when the
// Desktop started the sign-in with --app-return).
func Success(service string, appReturn bool) string {
	return render(page{
		title:     "Connected",
		iconClass: "icon-ok",
		icon:      "✓",
		heading:   "Connected",
		message:   html.EscapeString(service) + " is connected to Watchtower. You can close this tab.",
		appReturn: appReturn,
	})
}

// Error renders the page served when the provider redirected back with an
// error, or the code could not be turned into a token. reason is shown
// escaped.
func Error(reason string, appReturn bool) string {
	return render(page{
		title:     "Authorization failed",
		iconClass: "icon-err",
		icon:      "✕",
		heading:   "Authorization failed",
		message:   html.EscapeString(reason),
		hint:      "You can close this tab and try again in Watchtower.",
		appReturn: appReturn,
	})
}

type page struct {
	title, iconClass, icon, heading, message, hint string
	appReturn                                      bool
}

func render(p page) string {
	var b strings.Builder
	b.WriteString(`<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Watchtower — `)
	b.WriteString(p.title)
	b.WriteString(`</title>` + style + `</head><body>
<div class="card">
<div class="icon `)
	b.WriteString(p.iconClass)
	b.WriteString(`">`)
	b.WriteString(p.icon)
	b.WriteString(`</div>
<h1>`)
	b.WriteString(p.heading)
	b.WriteString(`</h1>
<p>`)
	b.WriteString(p.message)
	b.WriteString(`</p>
`)
	if p.appReturn {
		b.WriteString(`<a class="btn" href="` + AppReturnURL + `">Back to Watchtower</a>
`)
	}
	if p.hint != "" {
		b.WriteString(`<div class="hint">`)
		b.WriteString(p.hint)
		b.WriteString(`</div>
`)
	}
	// Best effort only: browsers ignore window.close() on a tab no script
	// opened, which is every tab here — hence the honest text above.
	b.WriteString(`</div>
<script>setTimeout(function(){try{window.close()}catch(e){}},` + closeAttemptMS + `);</script>
</body></html>`)
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
	return exec.CommandContext(ctx, "/usr/bin/open", u).Run()
}

// ReturnToApp brings the desktop app to the front by opening AppReturnURL
// through LaunchServices — the automatic half of app-return, done by the CLI
// once the sign-in has an outcome, since the browser cannot be relied on to
// follow a scripted redirect to a custom scheme. A no-op off macOS.
func ReturnToApp() error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return openURL(ctx, AppReturnURL)
}

// ReturnAfterLogin is what a CLI login command runs once its OAuth flow has
// returned, successfully or not: with appReturn (the Desktop started the
// sign-in) it brings the app back so the owner sees the outcome there.
// Skipped when ctx is already done — the Desktop cancelled the sign-in, so
// the owner is in the app already. A failure to open the app only warns: the
// sign-in itself is unaffected and the page still has the link.
func ReturnAfterLogin(ctx context.Context, appReturn bool, warn io.Writer) {
	if !appReturn || (ctx != nil && ctx.Err() != nil) {
		return
	}
	if err := ReturnToApp(); err != nil {
		fmt.Fprintf(warn, "warning: could not bring Watchtower to the front: %v\n", err)
	}
}
