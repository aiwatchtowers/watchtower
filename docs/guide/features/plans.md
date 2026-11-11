# Plans and subscription limits

**Usage → Plans** brings your Claude and Codex subscription limits together. Each subscription keeps its own percentages, reset times and forecast; API call costs are on **Usage → Watchtower**.

## Why use it
<!-- learn
id: plans-subscription-limits
title: Watch Claude and Codex limits
text: **Usage → Plans** shows each subscription's usage history and forecast before its own reset.
area: setup
level: next
kind: feature
since: 0.28.0
action: nav:usage
requires: feature:claude-plan-limits
replaces: [ai-plan-limits]
changed: Plans adds Codex subscription limits and independent refresh beside Claude.
-->

Watch your remaining allowance before starting a long session. Open the menu bar to see every current quota, including additional Codex buckets, and update one source without waiting for the other.

## How it works
<!-- learn: none -->

Watchtower reads your existing Claude Code and Codex sign-ins independently every five minutes. Reading the limits makes no AI model call. Failures back off to at most thirty minutes; the app rereads saved snapshots every thirty seconds.

The solid chart is usage history; the dashed line is the forecast at your recent pace. A forecast needs at least fifteen minutes of observations in the same window. Old data, an expired prediction or an unconfirmed Codex account hides the forecast with an explanation.

When Codex cannot confirm the account, only that response's current numbers appear; another account's history is never reused.

The menu bar keeps Claude's five-hour and weekly counters. Codex shows one quota: a reached limit first, otherwise the soonest forecast hit, otherwise the highest percentage. Its label uses that quota's actual duration.

Stale Codex numbers disappear from the bar; the popup keeps the provider's status and retry action.

Claude's system notifications warn once per limit and window: when the 5-hour or weekly limit is forecast to run out before it resets, and when any limit reaches 90%. Their switch is **Claude plan limits** in **Settings → Features → Notifications**. Codex information stays on Plans and in the menu.

Follow a service restriction message even when a quota's forecast stays below its limit.

## Using it
<!-- learn: none -->

1. Open **Usage → Plans**. The cards show each subscription separately.
2. Pick **Weekly** or **5 hours** to inspect that window. A source without the selected window explains the absence.
3. Press the header's **Refresh** to update both sources, or **Refresh** / **Retry** on one card to update just that source.
4. Open the menu bar for all quotas and provider actions. Press a quota or **Open Plans** to return to the screen.
5. Use **Show limits in the menu bar** to show or hide both counters. **Subscription plan limits** in **Settings → Features** switches both readers on or off.

## When it's empty or wrong
<!-- learn: none -->

- **No plan data:** sign in to the corresponding installed command-line tool, then retry. Codex needs a ChatGPT subscription sign-in; an API key alone supplies no subscription quotas.
- **Sign-in expired:** use Claude Code so it can refresh its own sign-in, then press **Refresh**. Watchtower does not refresh Claude credentials.
- **Unsupported Codex tool:** update Codex, then retry. Watchtower does not start a login flow for you.
- **Collecting data:** leave the reader running for at least fifteen minutes. A changed reset window or account starts a new history.
- **Forecast needs an update:** refresh; the previous predicted hit time has passed.
- **Saved limits could not be read:** retry. One provider's error leaves the other provider usable.

The quotas are information only and do not pause Watchtower's work. For high AI consumption, follow [Plan limits and high cost](../troubleshooting/plan-limits-or-high-cost.md).

## Related

- [AI providers, models and cost](../concepts/ai-providers-and-cost.md)
- [The Claude or Codex tool is not found or not signed in](../troubleshooting/ai-tool-not-found-or-not-signed-in.md)
- [Command line](../reference/cli.md)

For developers: [Subscription plan limits](../../features/claude-plan-limits.md)
