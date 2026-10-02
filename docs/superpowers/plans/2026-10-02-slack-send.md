# Slack send — implementation plan (2026-10-02)

Spec: `docs/superpowers/specs/2026-10-02-slack-send-design.md`. Board #166.
One PR, branch `feature/slack-send`. Tasks run in order in one lane.

## Task 1 — Slack scope + client (Go)

- `internal/auth/oauth.go`: `UserScopes += "chat:write"`; `OAuthResult.Scope`
  from `AuthedUser.Scope` (both `Complete` and the CLI login path).
- `internal/slack/token_store.go`: `Token.Scope` (`json:"scope,omitempty"`),
  `HasChatWrite(*Token) bool`.
- `cmd/slack.go`: `connectSlackAccount` saves the scope.
- `internal/slack/client.go`: `PostMessage(ctx, channel, text, threadTS) (ts,
  error)`, `OpenDM(ctx, userID) (channelID, error)`; history/replies already exist.
- `slack-app-manifest.json`: `chat:write` user scope.
- Tests: scope recorded on connect; `HasChatWrite` (missing/empty/present);
  `PostMessage`/`OpenDM` against an httptest server (params, error mapping).

## Task 2 — Registry: propose-only under DirectApply, Approve with revise

- `tools.Tool`: `ProposeUnderDirectApply bool`, `Revise`, `Ready` hooks.
- `directApplyGate`: an External tool passes only when it opts in and names
  the surface; `resolveTrust` keeps External = ask, so it lands `pending`.
- `Registry.Approve(ctx, id, patch)`; `db.ReviseAgentActionArgs(id, old, new)`
  (CAS on pending + old args).
- `cmd/actions.go`: `approve --patch`.
- Tests: `TestDev06_ExternalToolRefusedUnderDirectApply` unchanged and green;
  new `TestDev06_ProposeOnlyExternalToolLandsPendingUnderDirectApply` (one
  pending row, project context, never executed); Approve: no patch = old
  behaviour; patch on non-pending refused; patch on a tool without Revise
  refused; Ready failure leaves the row pending; concurrent revise CAS.
  `cmd`: `approve --patch` round trip.

## Task 3 — `send_slack_message` + `get_writing_style` (Go)

- `internal/tools/slack_send.go`: args, resolution, Normalize pin, Revise,
  Ready, Execute (scope check, DM open, mention rewrite, retry lookup).
  `SlackSender` interface + `SlackSenderFactory`.
- `internal/tools/style.go`: `get_writing_style`.
- `cmd/actions_registry.go`: register both; sender factory from the token store.
- `internal/chat/actions_contract.go` + fixture main: the tool line + style rule.
- Inventory: `docs/inventory/agent-actions.md` (AGENT-01 note, changelog),
  `docs/inventory/dev-surface.md` (DEV-06 rule 3); feature doc
  `docs/features/slack-send.md` + CLAUDE.md index line.
- Tests: resolution table (channel by name/id/link, thread link, DM by
  email/name/id, unknown, same-account duplicate → error, cross-account →
  candidates); propose writes one pending row and never calls the sender;
  Execute: unpicked → error, scope missing → hint, legacy token +
  `missing_scope` → hint, DM open, mention rewrite + foreign mention refused;
  Retry: landed found → no post, `reused`; lookup error → no post; nothing
  landed → post. `TestBuildToolRegistry_…` pins updated (project surface: the
  one External tool is propose-only).

## Task 4 — Desktop (Swift)

- `AgentToolsContract.swift` main list mirrors the Go fixture.
- `ReactionToolCatalog`: "Send to Slack".
- `AgentActionCardView+Slack.swift`: summary lines, editable text + picker,
  `canApprove`, retry note, Reconnect button (closure).
- `AgentActionFeed.approve(_:patch:)` → `actions approve <id> --patch …`.
- `ProjectNotificationPolicy`: `actionAwaitsApproval` + snapshot watermark
  (decode-compatible); `ProjectQueries.activitySnapshot` reads pending
  project-bound rows; notification routes to the Inbox strip.
- Tests (WatchtowerCore): contract fixture match, catalog title, card summary
  lines/canApprove/patch building, policy edges (new pending → one notice;
  baseline silent; old snapshot decodes).

## Task 5 — Docs, review, ship

App guide (Inbox strip + chat card + reconnect), review (local-review, then
debate-review), PR, CI, merge, board.
