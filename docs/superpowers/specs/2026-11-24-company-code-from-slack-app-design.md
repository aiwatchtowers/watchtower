# Company code from the Slack app — design (short)

Target: workbench #1155. Status: draft. Spike S1.2 (ask #888): an ordinary member does NOT find the bot-less app. Second spike (bare bot user) pending.

## Intent

A colleague who installs Watchtower at a company that already ran **Set up for my company** often does not know the company code. Posting the code in a channel is rejected by the owner (noisy, gets lost, reaches guests). The code must be findable by the colleague on their own, with no server and no bot that answers.

## What exists

- `company publish` writes `AboutText` (`internal/company/about.go`) into the company Slack app's `long_description`: "Watchtower for <company> — connect: <link>", then "Connect code: <code> — paste it in …", then the download line. The About page is visible to every member of the workspace who opens the app.
- The app is user-scope only (`internal/slackmanifest`): no `features.bot_user`, no App Home, no Interactivity, no Events.
- `aboutLeadsWithCode = false` (S1.2 default): the link leads; flip only when a URL in `long_description` is not clickable.
- Desktop: the Companies zone has a **Company code** field (`CompanyConnectionsPresentation.codePlaceholder`) and **Connect**, with no hint on where the code comes from (only `codeInvalid` mentions the About page, after a failure).

## Goals

- The colleague learns, next to the code field, where to find the code: in Slack, the company's Watchtower app → About.
- The app is actually findable by an ordinary member and its About shows a working link and a copyable code.

## Non-goals / anti-goals

- No DM push, no Home tab publishing, no slash command (owner dismissed ask #885; each needs either a server or the admin's Mac pushing to everyone).
- No backend, no DNS discovery.
- Never an Interactivity or Event Subscriptions Request URL on the app.

## Approaches

1. **About page + hint in the app (picked).** Zero infrastructure: Slack serves About to everyone. Depends on the app being findable.
2. **Bot DMs the link to everyone / newcomers.** Rejected: spam on large workspaces, the admin's Mac must be awake, the owner dismissed it.
3. **Home tab via `views.publish`.** Rejected as primary: per-user publishing from the admin's Mac, and Home is no easier to find than About.

## Spike S1.2 (ask #888) decides

| Finding | Change |
|---|---|
| App found by search / Apps list, About opens, link clickable | Hint only |
| Link not clickable | Also `aboutLeadsWithCode = true` (+ update `about_test.go` and the feature note's S1.2 line) |
| App not found by an ordinary member | Also add a bare bot user to the manifest (`features.bot_user`, no message scopes) so the app gets its own page; `MergeManifest` must add it on adopt, which means the admin re-approves the app — state that in the guide |

## Bot user (spike #888 outcome: the app is not found)

- Manifest: `features.bot_user` (`display_name` "Watchtower", `always_online` false) and one harmless bot scope, `team:read`; no message scopes, no Events, no Interactivity, Messages tab off.
- `slackconnect.AuthorizeURL` adds `scope=team:read`: a bot user is created only by an install that requests a bot scope. The bot token in the exchange answer is discarded, never stored or logged.
- `slackapp.MergeManifest` (adopt) adds the bot user and the scope; `ManifestChanges` reports `add_bot_user` so the dry run and the confirm screen name it. An installed app needs one re-approval by a workspace admin before the bot appears — the guide says so.
- Open until the second spike: whether Slack creates a bot user with zero bot scopes (then no scope at all), and whether the bot makes the app findable and opens on About.

## Design

- Desktop: one caption line under the **Company code** field in the Companies zone, always shown (not only after a failure): "No code? In Slack, find the **Watchtower** app and open **About**." The string lives in `CompanyConnectionsPresentation`; the onboarding/other places that show the code field reuse it. A screenshot and mockup go with the PR per the target procedure.
- `codeInvalid` stays as is.
- Guide: `docs/guide/start/company-setup.md` — "Connect with your company's link or code" gets the same sentence; the troubleshooting list gets "You do not have the code".
- Feature note `docs/features/company-setup.md`: S1.2 resolved, with the outcome.

## Left to the builder

- Exact view that hosts the code field and whether the caption fits the existing row layout (design kit caption style).
- If the admin renamed the app on adopt, the hint says "Watchtower" anyway; the About text names the company, which is enough.
