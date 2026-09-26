package mcpoauth

// callbackSuccessPage and callbackErrorPage are the pages served on the
// loopback OAuth callback — internal/jira/auth.go's page shape byte for
// byte, reworded for a generic MCP connection instead of a Jira site.

const callbackSuccessPage = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Watchtower — Connected</title>
<style>body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;background:#0f0f0f;color:#e5e5e5}
.card{background:#1a1a1a;border:1px solid #2a2a2a;border-radius:16px;padding:48px;max-width:440px;text-align:center}
h1{font-size:20px;margin-bottom:8px}p{color:#888;font-size:14px}
.btn{display:inline-block;margin-top:20px;padding:10px 20px;border-radius:8px;background:#2a2a2a;color:#e5e5e5;text-decoration:none;font-size:14px}</style></head>
<body><div class="card"><h1>Connected</h1><p>This connection has been signed in to Watchtower. You can close this tab.</p><!--RETURN--></div>
<script>setTimeout(function(){try{window.close()}catch(e){}},{{CLOSE_MS}});</script></body></html>`

// appReturnBlock is injected into the success page when LoginOptions.AppReturn
// is set — mirrors jira.jiraAppReturnBlock/slack.appReturnBlock. The button is
// the manual fallback if the automatic scheme redirect is blocked.
const appReturnBlock = `<a class="btn" href="watchtower-auth://connected">Open Watchtower</a>
<script>setTimeout(function(){location.href="watchtower-auth://connected";},3000);</script>`

const callbackErrorPage = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Watchtower — Error</title>
<style>body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;background:#0f0f0f;color:#e5e5e5}
.card{background:#1a1a1a;border:1px solid #2a2a2a;border-radius:16px;padding:48px;max-width:440px;text-align:center}
h1{font-size:20px;margin-bottom:8px}p{color:#888;font-size:14px}</style></head>
<body><div class="card"><h1>Authorization Failed</h1><p>{{ERROR}}</p></div></body></html>`
