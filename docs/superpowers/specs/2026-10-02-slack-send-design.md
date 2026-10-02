# Slack send from the AI chat and the project terminal — design (2026-10-02)

Board target #166. Owner decisions of 2026-10-02 are fixed inputs (§1); this
document only decides how they land in the code.

## 1. Owner decisions (not re-opened)

1. The assistant drafts the message in the owner's style (`workspace.style_profile`)
   → an `agent_actions` proposal card (recipient + workspace + text preview; the
   owner can edit the text) → Approve sends it with `chat.postMessage` under the
   owner's **user** token, applied exactly once (AGENT-05). Nothing is sent
   without Approve.
2. Project terminal (`watchtower mcp --project N`): the tool only **proposes**;
   the card appears in Watchtower Desktop (with a notification) and is sent after
   the owner's Approve there — the same exactly-once path as the chat.
3. Several Slack workspaces: the recipient decides the account. When it is
   ambiguous (the same channel name in two workspaces) the card shows a
   workspace picker before Approve. The account is fixed at propose time and
   never re-resolved at apply (the PR #92 rule for Jira).
4. Sending needs the `chat:write` user scope. Existing accounts re-authorize; a
   send without the scope fails with a visible "sign in again to grant send"
   error, never silently.

## 2. The tool: `send_slack_message`

A registry write tool (`internal/tools/slack_send.go`), `External: true` (it
leaves the machine — AGENT-03: never `execute` trust), `Surfaces: ["main",
"project"]`. Not on the target chat (v1: its mandate is the task's vertical
line), not on reaction or draft-only surfaces (AGENT-04 unchanged).

Arguments (model-facing):

| arg | meaning |
|---|---|
| `channel` | `#name`, a channel id (raw or `<acct>:<id>`), or a Slack link to a channel or message |
| `thread_ts` | reply in this thread (a message link carries it too) |
| `user` | DM recipient: user id (raw or namespaced), `@handle`, display/real name, or email |
| `account_id` | optional: pick the workspace when the model already knows it |
| `text` | the message, Slack mrkdwn, ≤ 4000 characters; mention people as `<@USER_ID>` |
| `reason` | why (shown on the card) |

Exactly one of `channel` / `user`. `thread_ts` only with `channel`.

**Resolution (Validate + Normalize, at propose time, from the local DB only).**
Candidates are looked up across enabled, non-removed Slack accounts
(`account_id` narrows to one): a channel by id, by link (the link's host picks
the account by `team_domain`), or by name among non-archived public/private
channels; a person by id, email, handle, display or real name among non-deleted,
non-bot users. Zero matches → a `ValidationError` naming what was not found. More
than one match **inside one account** (two people called Alex) → a
`ValidationError` listing them — the model asks the owner. Exactly one match in
each of several accounts → a cross-workspace ambiguity: the proposal is recorded
with `candidates` and no `target`, and the card shows the picker.

Normalize pins the result into the stored args: `target = {account_id,
workspace, channel_id, user_id, label, thread_ts}` (raw Slack ids;
`channel_id` empty for a DM whose IM channel is not synced yet) or
`candidates = [target…]`. Execute never re-resolves names.

**Execute (Apply only).** Refuses a row without `target` ("choose the workspace
on the card first"). Loads the pinned account (must still be enabled and not
removed) and its token file; a token whose recorded scopes lack `chat:write`
fails at once with the re-auth error (§5), a legacy token without recorded
scopes is tried and Slack's `missing_scope` maps to the same error. A DM without
a channel opens it (`conversations.open`). Namespaced mentions of the pinned
account (`<@2:U…>`, `<#2:C…>`) are rewritten to raw ids; a mention namespaced to
another account fails the send. Then `chat.postMessage(channel, text,
thread_ts)`. Result: `{channel_id, ts, url (permalink), label, workspace}` — the
card's generic url+label link shows it.

**Retry is exactly-once too.** On `Call.Retry` (the row had failed: a timeout may
have landed the message) Execute first reads the conversation (thread replies or
channel history) since the proposal's `created_at` and reuses a message from the
owner with the same text (`reused: true`). A failed lookup fails the retry rather
than re-sending — the `create_jira_issue` rule.

## 3. Style: `get_writing_style`

A read tool registered in `buildToolRegistry` only (not `ReadTools()`, so dev-mode
MCP is unchanged — DEV-01), `Surfaces: ["main", "project"]`. Returns the stored
`style_profile`, its `updated_at`, and a hint when it is empty (`watchtower
inbox style-sample` / the Profile tab). The main chat's actions contract and the
tool description tell the model: call it first, draft in the owner's language
and tone for that audience, keep it short, never invent facts.

## 4. Editing and the workspace picker: `Registry.Approve`

New optional tool hooks:

- `Revise(ctx, d, stored, patch) (args, error)` — merges an owner edit into a
  **pending** row's stored args. For `send_slack_message`: `text` (re-validated:
  non-empty, ≤ 4000) and `candidate` (an index into the pinned `candidates`,
  which sets `target`). Nothing else is editable — the recipient stays what was
  proposed or one of the pinned candidates.
- `Ready(args) error` — what must hold before a row may be approved
  (`send_slack_message`: a `target` and non-empty text).

`Registry.Approve(ctx, id, patch)` = optional revise (CAS on `status='pending'
AND args_json=<old>`, so a concurrent decision or edit is refused, not
overwritten) → `Ready` → the existing `pending → approved` transition. `watchtower
actions approve <id> [--patch '<json>']` calls it; with no patch and no hooks it
is byte-for-byte today's approve. Apply/exactly-once is untouched.

## 5. Scope and re-authorization

- `auth.UserScopes` gains `chat:write`; `slack-app-manifest.json` too. **Owner
  action:** the live Slack app's user-token scopes must include `chat:write`
  (api.slack.com → OAuth & Permissions) before a re-auth can grant it.
- The token file (`slack_token_<id>.json`) records the granted scopes (`scope`,
  from `authed_user.scope`); `HasChatWrite(tok)` is true only when it is recorded
  and contains `chat:write`.
- The failure message carries the stable phrase **"sign in again to grant
  send"** (`tools.SlackSendScopeHint`), mirrored in Swift: the card then shows a
  **Reconnect Slack** button that runs the existing `slack login --account <id>
  --app-return` re-consent (`SlackAccountsViewModel.relogin`); after it, Retry
  sends.

## 6. Project terminal

`directApplyGate` today refuses every External tool under `DirectApply` (DEV-06
rule 3). New opt-in `Tool.ProposeUnderDirectApply`: such a tool (it must name the
`project` surface and be External) is recorded as a **pending** proposal with
the project binding — never applied inline, trust `ask` — and the model gets
the usual pending receipt ("the owner approves it in Watchtower Desktop"). Every
other External tool is still refused exactly as before
(`TestDev06_ExternalToolRefusedUnderDirectApply` unchanged).
`send_slack_message` is the only tool with the flag. DEV-06 and AGENT-01 are
amended (owner decision 2 above), with a new guard.

Desktop: the Inbox **Actions** strip already shows every non-terminal row of any
surface, so the card appears there. `ProjectNotificationPolicy` gains an
`actionAwaitsApproval` notice (watermark = the highest project-bound pending
`agent_actions` id; "Send to Slack awaits your approval", body = recipient +
text start); clicking it opens the Inbox strip.

## 7. Desktop card

`AgentActionCardView` renders `send_slack_message`: "To: #channel · workspace"
(or "Reply in thread in #channel", "DM @person"), the text. While `pending`: an
editable text field (prefilled from the args) and, with `candidates`, a
workspace picker; Approve is disabled until a workspace is chosen and the text
is non-empty, and sends `--patch` only when something changed. Failed with the
scope phrase → Reconnect Slack. The retry note for this tool says the retry
first checks whether the message already landed. `ReactionToolCatalog` names
the tool ("Send to Slack"). The actions contract (Go + Swift twin + fixtures)
lists the tool and the style rule.

## 8. Contracts

- AGENT-01/DEV-06 amended (§6); AGENT-03/05 unchanged and covered for the new
  tool (`TestAgent03_…`-style refusal of execute trust, the claim).
- New guards: the propose-only DirectApply path writes one `pending` row and
  never executes; `send_slack_message` never sends on propose; Execute refuses
  an unpicked candidate; a retry that finds the landed message does not re-post;
  a lookup failure does not re-post; a missing scope fails with the hint.

## 9. Out of scope (v1)

Target chat surface; editing a failed row before Retry; scheduled sends,
attachments, blocks; a Settings-level "cannot send" badge (the card is where the
owner meets the error); resolving `@name` inside the text to mentions.
