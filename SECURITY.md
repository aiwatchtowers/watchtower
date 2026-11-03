# Security Policy

## Reporting a vulnerability

Please report security problems privately through GitHub: open the
repository's **Security** tab and choose **Report a vulnerability**
([direct link](https://github.com/aiwatchtowers/watchtower/security/advisories/new)).

Do not open a public issue, pull request or discussion for a vulnerability.

A useful report includes:

- what is affected (the app, the `watchtower` CLI, the daemon, the iPhone app)
  and the Watchtower version (`watchtower version`, or **About Watchtower**)
- steps to reproduce, or a proof of concept
- what an attacker gains

Leave real messages, names and account details from your own install out of
the report; a description or a redacted sample is enough.

We will acknowledge the report, keep you updated while we work on a fix, and
credit you in the advisory unless you prefer otherwise.

## Supported versions

Only the [latest release](https://github.com/aiwatchtowers/watchtower/releases/latest)
receives security fixes. Please check that the problem still happens there
before reporting.

## Scope

Watchtower is local-first:

- Synced data (Slack, Gmail, Calendar, Jira, Confluence, Linear, meeting
  transcripts) is stored on your Mac under `~/.local/share/watchtower`, and
  configuration under `~/.config/watchtower`. There is no Watchtower server
  that holds your data.
- AI features run through the provider you set up yourself: the Claude Code
  or Codex CLI signed in to your own account, or a local Ollama-compatible
  server. Text sent to that provider is handled under its own terms.
- The optional iPhone companion syncs through your own iCloud account,
  end-to-end encrypted between your Mac and your phone.

In scope: anything that lets another person, another app or a crafted message
read or change your Watchtower data, run commands, or act on your connected
accounts without your approval. Examples: prompt injection that leads to an
unapproved write, a sandbox escape in automations or HTML previews, a token or
secret leak, or data written to logs or temporary files where it should not be.

Out of scope: vulnerabilities in the third-party services and AI CLIs
themselves (report those to their vendors), and attacks that require someone
who already controls your macOS user account.
