# Mobile catch-up — work plan (2026-08-03)

Branch: `mobile-app` (integration). Worktree: `.claude/worktrees/mobile-app`.

**Merge rule: PRs into `mobile-app` MUST use a merge commit, never squash.** #59 was squashed, the merge parent was lost, and the next main merge replayed 272 commits (28 conflicts); repaired by an `ours`-merge (`eda352ac`). See `project_mobile_app` memory.

## Done

- PR #59 — main (transcriber D1–D3, secretary memory, Google multi-account, IMAP/Outlook) → `mobile-app`, plus `feature/mobile-situations`, plus the Swift 6 concurrency fixes.
- PR #60 — Slack multi-account (#58) + ancestry repair. `origin/main` is now a full ancestor of `origin/mobile-app`.

## Remaining, in order

1. **Slack id namespacing on the phone** (correctness, do first — the phone is currently wrong, not just incomplete).
   Slices now carry `<accountID>:<rawID>` (e.g. `1:C0123`, `1:U0456`) in `inbox_items.channel_id`, `digests.channel_id`, `targets.ball_on`, `tracks.ball_on`/`assignee_user_id`, `people_cards.user_id`.
   - Slack deeplinks must split the prefix and resolve the owning workspace's `team_id` (desktop precedent: `resolveLinkTarget` in `internal/ai/context_builder.go`, `internal/slack/namespace.go`).
   - Own-message detection is now a SET of owner ids (`db.ListOwnerSlackUserIDs`), not one.
   - One human in two workspaces = two `people_cards` rows; the UI must not assume uniqueness.
2. **Meeting transcripts on the phone** — new slice kind for `meeting_transcripts` (recap + `notes_md` + snippet; the full transcript is large, likely relay-only like raw Slack) and a Recordings screen. Mirror `list_transcripts`/`get_transcript` into `ReplicaToolbox` for the BYOK agent.
3. **Multi-account status in mobile Settings** — read `google_accounts` and `slack_accounts` (email/label, badges, status/error); hide data from disabled/removed accounts.
4. ~~**Per-situation Discuss chat**~~ — done 2026-08-04 (`feature/mobile-situation-chat`). The phone's turn joins the DESKTOP's conversation for that situation, so the memory chat ingest sees phone-authored owner turns too. Relay-only (the on-device agent refuses a bound thread); desktop-authored turns are not synced down in v1.
5. ~~**Day plan on Today**~~ — done 2026-08-04 (`feature/mobile-day-plan`, stacked on 4). Today's plan publishes as two slice kinds, with done/skip actions. Note: `day_plan_items.status='skipped'` was a dead state — that branch also taught the desktop to render it.

Both are specced in `2026-08-04-mobile-situation-chat-day-plan.md`.

## Standing gotchas

- `make mobile-test` shares one on-disk replica with the simulator's installed app; stale seed state fails `ReplicaWiringTests` with wrong counts. `xcrun simctl uninstall "iPhone 17 Pro" com.aiwatchtowers.watchtower.mobile` before believing a failure.
- A lone Swift Test job stalling in CI (~3h, no output) was a runner flake on 2026-08-02; rerun passed in 4m41s.
- `ANTHROPIC_LIVE_KEY=... make smoke-live` is still a MUST before any user-facing ship (the wire fixture never met the real server).
- `feature/jira-multi-account` exists on origin — the third multi-account sub-project will need the same treatment once it lands on main.
