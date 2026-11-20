# Watchtower security surfaces

The attack surfaces the `/security-audit` skill
(`.claude/skills/security-audit/`) hands to the audit engine as context, and the map
its Range mode uses to say which surfaces a tag diff touches.

Format, per surface: `Paths:` is a fenced block of git pathspecs, one per line (a
directory prefix ending in `/` matches everything under it; `*` matches across `/`, as
in `git diff --name-only <a>..<b> -- <pathspec>…`). Every pathspec matches at least one
tracked file. `Feature notes:` are files in `docs/features/`; `Inventory:` ids are
contracts in `docs/inventory/` (load-bearing: a fix that weakens one needs the owner's
decision). A path may sit under more than one surface.

## llm-injection

Untrusted text (Slack, mail, Confluence, Jira, Linear, web pages, image descriptions,
meeting transcripts) reaching the model, and the model's output reaching tools, writes,
automations, memory and later prompts.

Paths:
```
internal/tools/
internal/prompts/
internal/chat/
internal/chatengine/
internal/agentloop/
internal/memory/
internal/inbox/
internal/media/
internal/kb/
internal/reactioncmd/
internal/confluenceedit/
internal/slacklive/
internal/watchman/
internal/watchmanact/
internal/externalmcp/
internal/mcp/
internal/automations/sdk_agent.go
internal/automations/sdk_mcp.go
internal/automations/sdk_llm.go
internal/ownerconfirm/
cmd/actions*.go
WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/
WatchtowerChat/Sources/ChatWire/Actions/
```

Feature notes: `agent-actions.md`, `automations.md`, `built-in-automations.md`,
`bulk-read-limits.md`, `chat-claude-ai-tools.md`, `confluence-page-editing.md`,
`slack-send.md`, `slack-live.md`, `memory.md`, `attention-detection.md`,
`reaction-commands.md`, `media-knowledge.md`, `watchman.md`, `quick-connections.md`,
`developer-surface.md`.

Inventory: AGENT-01…07, AUTO-01…03, AUTO-06, AUTO-07, READ-01, READ-02, CHAT-02,
CHAT-05, LIVE-01, EXT-05, MEM-01, MEM-08, QC-02, DEV-01, WATCHMAN-01…04.

Entry points: synced message, mail, issue and page bodies; image descriptions and
fetched link summaries (`internal/media`); meeting transcripts; external MCP tool
results; recipe text the owner did not write (workbench `.watchtower/automations/`).

Sinks: the tool registry (`internal/tools`, `buildToolRegistry`) and its write tools
(Slack send, Confluence edit, Jira/Linear writes); automations `agent()`/`mcp()`;
memory beliefs and the vault; inbox items and prompts built from stored text; the
Watchman twin's answers to sessions.

Strongest control: the model never writes — writes are proposals applied exactly once
after the owner's approval (AGENT-01, AGENT-05, AGENT-07, owner confirmation through
`internal/ownerconfirm`); external MCP tools never auto-execute (AGENT-03, QC-02);
company-data reads are budgeted (READ-01).

## local-endpoints

Everything on the owner's machine another local process, a web page or a link can talk
to.

Paths:
```
WatchtowerDesktop/Sources/WatchtowerCore/Services/LocalPreview/
WatchtowerDesktop/Sources/Views/Common/SandboxedHTML*.swift
WatchtowerChat/Sources/ChatUI/Platform/macOS/SandboxedHTMLGlue.swift
WatchtowerChat/Sources/ChatUI/Text/AllowedURLSchemes.swift
WatchtowerChatText/Sources/WatchtowerChatText/HTMLPreviewPolicy.swift
WatchtowerChatText/Sources/WatchtowerChatText/NavLink.swift
WatchtowerDesktop/Sources/App/WatchtowerApp.swift
WatchtowerDesktop/Sources/Services/SessionHost/
internal/sessionhost/
cmd/session_host.go
internal/chatengine/server.go
internal/chatengine/conn.go
internal/tower/socket.go
internal/hub/control.go
internal/platform/
internal/ownerconfirm/
internal/mcp/
cmd/mcp.go
internal/auth/callback.go
internal/mcpoauth/login.go
internal/slackconnect/server.go
WatchtowerDesktop/Resources/WatchtowerCloudBridge/Info.plist
```

Feature notes: `html-artifacts.md`, `unified-chat.md`, `tower-interface.md`,
`workbench.md`, `go-hub.md`, `developer-surface.md`, `in-app-help.md`.

Inventory: CHAT-05, PROJ-12, PROJ-16, PROJ-20, PROJ-21, PROJ-23, DEV-06, AGENT-07.

Entry points: `LocalPreviewServer` (127.0.0.1, random port, per-folder token);
`chat.sock`, `tower.sock`, the session-host socket and the hub control socket; MCP
stdio servers (`watchtower mcp`, `--workbench`, `--chat`); OAuth loopback callback
listeners; the `watchtower-nav://` and `wtpreview:` schemes; HTML in
`SandboxedHTMLView`; links opened through `NSWorkspace`.

Sinks: session input (lines typed into a hosted agent, permission answers), chat turns
and tool approvals, files served from a workbench folder, external apps launched by a
URL.

Strongest control: unix sockets 0600 (`tower.sock` and `hub.sock` in a 0700
directory with a peer uid check); `chat.sock` grants every operation only to the
signed Watchtower app (peer audit token and `codesign` in `internal/chatengine/conn.go`),
and `tower.sock` re-checks the Desktop peer by audit token (`internal/ownerconfirm`);
the preview server's Host check,
GET/HEAD only, root confinement and `connect-src 'none'` CSP; `HTMLPreviewPolicy`
blocking non-local loads.

## auth-secrets

OAuth flows, stored tokens and secrets crossing process boundaries.

Paths:
```
internal/auth/
internal/oauthclient/
internal/oauthpage/
internal/mcpoauth/
internal/slackauth/
internal/slackconnect/
internal/slackapp/
internal/company/
internal/companybundle/
internal/atlassianpdr/
internal/gmail/auth.go
internal/calendar/auth.go
internal/jira/auth.go
internal/linear/oauth.go
internal/imap/outlook_auth.go
internal/imap/credentials.go
internal/caldav/credentials.go
internal/logredact/
internal/logcanary/
internal/fsutil/
cmd/google*.go
cmd/slack*.go
cmd/company*.go
cmd/oauth_resolve.go
cmd/connections.go
```

Feature notes: `files-outside-db.md`, `google-multi-account.md`,
`slack-multi-account.md`, `slack-full.md`, `jira-multi-account.md`, `linear.md`,
`company-setup.md`, `quick-connections.md`.

Inventory: FILES-01, CHAT-04, QC-03, SLACKFULL-01, SLACKFULL-02, LINEAR-02,
LINEAR-03, PURGE-01, PURGE-02 (client records), POLICY-01.

Entry points: OAuth redirects to loopback callbacks (state, PKCE in
`internal/auth/pkce.go`); company bundles and setup links; owner-entered API tokens
and IMAP/CalDAV passwords; MCP server OAuth discovery.

Sinks: token files (0600 by owner decision, not the Keychain); argv and environment
of child processes; logs, crash output and temp files; prompt payloads.

Strongest control: tokens in 0600 files; secrets and prompts passed over inherited
pipes (`fsutil.AttachPayloads`, `/dev/fd/N`), never argv (CHAT-04, QC-03); logs carry
ids and fingerprints only (FILES-01, `logredact`, `logcanary` guard tests).

## crypto-sync

Keys and encrypted transport: the database engine, the phone link and its transports.

Paths:
```
internal/sqlcipher/
internal/db/db.go
internal/hub/
cmd/hub*.go
WatchtowerKit/Sources/
WatchtowerMobile/Sources/
WatchtowerDesktop/Sources/CloudBridgeCore/
WatchtowerDesktop/Sources/WatchtowerCloudBridge/
WatchtowerDesktop/Sources/ViewModels/MobilePairingModel.swift
```

Feature notes: `db-encryption.md`, `mobile-companion.md`, `relay-client.md`,
`go-hub.md`, `live-link.md`, `iphone-chat.md`.

Inventory: FILES-02 (planned), PROJ-16, PROJ-21, FEED-05.

Entry points: pairing (pair zone, SAS confirm, grants in `internal/hub/link`); relay
and CloudKit records arriving at the hub and the phone; App Attest on the phone.

Sinks: the hub's sealing (`internal/hub/secure`, Kit `EnvelopeSealer`), the hub
identity key file, actions applied from the phone (`internal/hub/actions`), alert
pushes.

Strongest control: one sealing choke point per side with shared E2E test vectors;
an ordered exactly-once action ledger. Database encryption is Stage 1 only: the
SQLCipher engine ships, but every file is still plaintext.

## exec-sandbox

Code and processes Watchtower runs: automation scripts, agent sessions, git, children.

Paths:
```
internal/automations/sandbox*.go
internal/automations/sdk_shell.go
internal/automations/sdk_session.go
internal/automations/policy_check.go
internal/sessionhost/
internal/sessionstart/
internal/terminal/
internal/claude/
internal/codex/
internal/claudesession/
internal/gitbin/
internal/workbenchgit/
internal/workbenchfolders/
internal/sessioncleanup/
internal/policy/
cmd/workbench_cleanup.go
cmd/workbench_git.go
cmd/workbench_merge.go
WatchtowerDesktop/Sources/Services/CodeCLIProcess.swift
WatchtowerDesktop/Sources/Services/TerminalCenter*.swift
```

Feature notes: `automations.md`, `workbench.md`, `adding-a-harness.md`,
`diff-reviewer.md`, `mdm-policy.md`, `tray-daemon-lifecycle.md`.

Inventory: AUTO-07, AUTO-08, AUTO-12, AUTO-13, PROJ-10, PROJ-18, PROJ-24,
REVIEW-01, REVIEW-05, POLICY-01…03, LLMTRANSPORT-01.

Entry points: recipe JS run in goja; `shell()`/`session()` from a recipe; session
start from the Desktop or the phone; git over a folder the owner opened (an untrusted
repository's config and hooks); message text reaching a CLI argument.

Sinks: `exec` of `claude`, `codex`, `git` and recipe shell commands; PTYs; file
removal by session cleanup and worktree merge; the environment a child inherits.

Strongest control: the goja lockdown (no eval/timers/promises, regex timeout,
allocation caps, the SDK as the only door — AUTO-07) and exact shell commands only in
a workbench (AUTO-13); git calls hardened for background reads (REVIEW-05); cleanup
never removes unsaved, unpushed or in-use work (PROJ-18).

## network-ssrf

Outbound requests whose target an attacker can influence.

Paths:
```
internal/media/webfetch/
internal/media/linkrule/
internal/media/
internal/netsec/
internal/mcpoauth/discovery.go
internal/externalmcp/
internal/confluence/
internal/caldav/
internal/imap/
internal/slack/client.go
```

Feature notes: `media-knowledge.md`, `quick-connections.md`,
`confluence-knowledge-connector.md`, `knowledge-search.md`.

Inventory: KB-04, EXT-01, EXT-03.

Entry points: links in synced messages and pages; image URLs; owner-added MCP server
URLs and their OAuth metadata; IMAP/CalDAV hosts.

Sinks: `webfetch.Fetcher.Get` (redirects, dial), media downloads, credentialed
clients.

Strongest control: `linkrule.Fetchable` (ports 80/443, secret params/paths, synced and
company hosts denied — KB-04) and a dialer `Control` that checks every resolved
address against public ranges (`webfetch/addr.go`), including on redirects;
`netsec` refuses a secret over cleartext except to loopback.

## data-lifecycle

What happens to synced data: deletion, scoping, private content, policy, consent.

Paths:
```
internal/purge/
internal/sourcediff/
internal/sync/deletions.go
internal/gmail/deletions.go
internal/jira/deletions.go
internal/db/account_*.go
internal/db/slack_deletions.go
internal/db/meeting_transcripts.go
internal/kb/dirty.go
internal/meeting/
internal/policy/
internal/aiconsent/
internal/auditlog/
internal/backupexclude/
cmd/accounts.go
cmd/policy.go
cmd/meeting_transcript*.go
WatchtowerDesktop/Sources/WatchtowerCore/Services/ManagedPolicy*.swift
```

Feature notes: `revoke-purge.md`, `source-deletions.md`, `private-meetings.md`,
`mdm-policy.md`, `background-ai-consent.md`, `bulk-read-limits.md`,
`time-machine-exclusion.md`, `slack-adaptive-sync.md`, `google-multi-account.md`.

Inventory: PURGE-01, PURGE-02, SRCDEL-01…03, MEETPRIV-01…05, POLICY-01…03,
BGAI-01…03, READ-01, READ-02, BACKUP-01, SLACK-01, PROJ-02, PROJ-17.

Entry points: revoked access, source deletions and edits, private-meeting toggles,
managed preferences, account removal.

Sinks: every table, index, vault and derived store holding the data; prompt-feeding
readers; cross-account queries.

Strongest control: chunked purge with a ledger (PURGE-02); no deletion from a bad
listing and same-write KB updates (SRCDEL-01, SRCDEL-03); no prompt-feeding reader
sees a private recording (MEETPRIV-02). Known gap class: derived knowledge (memory,
digests) is not purged mechanically.

## supply-chain

What builds, signs and ships Watchtower, and what it downloads.

Paths:
```
.github/workflows/
scripts/
Makefile
go.mod
go.sum
*/Package.swift
*/Package.resolved
WatchtowerMobile/project.yml
WatchtowerMobile/*.entitlements
WatchtowerDesktop/Resources/WatchtowerCloudBridge/*.entitlements
internal/sqlcipher/VERSION
packaging/
WatchtowerDesktop/Sources/Services/Transcription/
```

Feature notes: `db-encryption.md`, `tray-daemon-lifecycle.md`,
`meeting-transcriber.md`, `voice-dictation.md`, `relay-client.md`.

Inventory: none.

Entry points: CI triggers and their inputs; dependency pins (Go modules, SwiftPM,
the vendored SQLCipher amalgamation, the relay proto pin); model downloads for
transcription and dictation; the Homebrew cask.

Sinks: the signed app bundle and CLI binary store, entitlements, release artifacts,
the pre-push hook.

Strongest control: exact pins (`go.sum`, `Package.resolved`, the GRDB fork pin,
`internal/sqlcipher/VERSION`) and the leak check (`scripts/leak-check.sh`, pre-push
and CI).
