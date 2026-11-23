# Writing the guide

Rules for every page in `docs/guide/`. A user-facing change updates its page in the same PR.

## Rules

1. **Every page is page one.** Give one line of context, then a link instead of "see above".
2. **Every section stands alone.** Headings say what the section answers ("Why the briefing skips a day"). The first sentence carries the answer. Never write "as mentioned".
3. **One kind of text per section.** Why and how it works explain. Using it gives steps, and explanation does not leak into steps. Reference is lists and tables. Troubleshooting is symptom to fix.
4. **Short.** Start from the reader's task and use one real scenario. Paragraphs are three sentences or fewer. A feature page stays under about 8 KB (`wc -c`); split it rather than grow it.
5. **Only what the screen doesn't say.** Keep schedules, preconditions, data sources and what a button really does. Put UI names, error text and shortcuts in **bold**, spelled as the app spells them.
6. **True to the code.** Check every schedule, default, condition, string and shortcut against the Go or Swift source. The code beats other docs.
7. **Only what ships on `main`.** No roadmap, no "coming soon".
8. **Voice.** Second person, present tense, plain words, lively without being jokey. "The assistant" is the only name for the AI persona.
9. **Public repo.** No real names, ids, domains or paths. Use `acme` and `example.com`.

Adding, renaming or re-titling a page changes the chat prompt golden: run `go test ./docs/guide/ ./internal/kb/ ./internal/chat/` (the Guide Check job's packages) and regenerate with `go test ./internal/chat -run TestBuildSystemPrompt_Golden -update`.

## Headings are anchors

Other pages and the in-app help agent link to headings. Use only `##` and `###`, and keep a published heading's text stable.

## Feature page template

```
# <Feature>
<lede: what it is and who it is for, 2-3 sentences>

## Why use it
## How it works
## Using it
## When it's empty or wrong
## Related

For developers: docs/features/<x>.md
```

Feature pages always keep the first four sections (Why use it, How it works, Using it, When it's empty or wrong), in this order. Only Related and For developers may be dropped.

## Troubleshooting page shape

The title is the symptom ("Briefings tab is empty"). Then:

1. What you see, with the exact UI or error text.
2. Why, in one or two sentences.
3. Fix, as ordered steps.
4. How to check it worked.
5. If it didn't, what to try next.

## Connect playbooks

A page under `connect/` is a connector's playbook: the connect assistant's script, a guide page and what the help chat answers from. It replaces the feature page template with this one, stays under 8 KB (`TestFeaturePagesUnder8KB`), and `internal/connectplay` parses it (`go test ./internal/connectplay`).

````
# Connect <service> with the assistant
<lede: what the assistant connects, and that Agent / You / You only say who acts>

## What you get
## Before you start          (accounts, admin rights, policy; "The assistant works only on <hosts>. It leaves any other page and stops.")
## Steps                     (one numbered list, numbered 1..n without gaps)
## If something goes wrong   (per failure: what you see, what to do; Set up by hand is always there)

```connect
service: slack
domains: api.slack.com, app.slack.com
tools: connect_status, connect_start, connect_wait, connect_cancel, request_secret
secrets: slack_config_token
options: pkce
```
````

The four sections come in this order; other `##` sections (Slack's `## Slack Live`) may sit between them. The page has exactly one `connect` block, one `key: a, b` per line:

- `service`: `slack`, `google`, `email`, `calendar`, `jira`, `linear`, `quickConnections`, `company` (the setup wizard) or `google_own_project`. `vendor` (`slack`, `google`, `atlassian`, `linear`, `microsoft`) is required for `company` and only there.
- `domains`: bare lowercase hosts the agent may work on: no scheme, path, port or wildcard.
- `tools`: connect tools from `connectplay.KnownTools`. `slack_live_probe` is allowed only in `slack.md`.
- `secrets`: `request_secret` kinds from `connectplay.KnownSecrets`. A page lists `secrets` exactly when its `tools` hold `request_secret`.
- `options`: the `connect_start` options the steps use.

Every item of a list with step tags starts with one tag, which says who acts:

- `1. **Agent:** …` the assistant: tool calls, and browser steps on the page's hosts. Written as an instruction to it.
- `2. **You:** …` the customer: sign-ins, 2FA, the final **Allow**, a confirm card.
- `3. **You only:** …` a click that shows a secret: Google's **Create** on the OAuth client form, Atlassian's app **Settings**, Slack's **Generate Token**. The agent step before it calls `request_secret`; the customer clicks, copies the secret into the card, leaves the page or closes the dialog, then presses **Send**. The parser fails a page whose other steps name such a page or button (`internal/connectplay/reveal.go`).
- `4. **Check:** …` how the assistant checks a step worked (`connect_wait`, `connect_status`).

**Links.** A page the agent or the customer opens is written as a full Markdown link, `[api.slack.com/apps](https://api.slack.com/apps)`, never a bare host or path: the agent copies the playbook's form into the chat, so the customer gets a link to click. The `Before you start` host list and the `domains` line stay bare hosts; a value the customer types (a deny-list host, a site) stays in `code`.

**Public safety.** A playbook is public and goes into the model's prompt: no real workspace, site or company names, no ids, no addresses outside `example.com`, no local paths (`TestPlaybooks_PublicSafe`). A secret never appears on the page, not even as a sample.

## Learn cards

Home's **Learn Watchtower** zone shows cards written in these pages. A card is an HTML comment right under the `##`/`###` heading it teaches; GitHub, the in-app guide, search and the 8 KB page limit never see it. A new user-facing capability brings its card in the same PR.

```
<!-- learn
id: inbox-snooze
title: Snooze a card until later
text: Press **Snooze** on an Inbox card and it comes back when you said.
area: communication
level: next
kind: tip
since: next
action: nav:inbox
-->
```

- `id`: kebab-case, page-prefixed, unique; never changed or reused once shipped (seen state is keyed by it).
- `title` ≤ 40 characters; `text` one sentence ≤ 120 characters, what it does for you and how to start.
- `area` (communication, meetings, tasks, development, assistant, planning, automations, iphone, setup), `level` (basics, next, power), `kind` (feature, tip, shortcut).
- `since: next` on a new card; the release stamps the version.
- Optional: `action` (`nav:<screen>`, `connect:<source>`, `turnOn:<featureID>`, `chat:<prompt>`, `hotkey:<name>`; without it the button is **Read more**), `requires` (`feature:<id>` or `source:<name>`), `done_when` (a signal that means "already uses it").
- A feature that changed gets a new card with `replaces: [old-id]` (list every id it supersedes) and may add `changed:` (one sentence on what changed); delete the old card.
- Deleting a card that has `replaces: [a, b]` (a newer card replaced it in turn): add one line per id to `internal/learn/retired.txt` (`a <deleted-id>`), so those ids stay retired and the newer card's chain still reaches them.
- A new `##` section that teaches nothing to try carries `<!-- learn: none -->`.
- `go test ./internal/learn/` validates every card; `watchtower guide learn` lists them. The full vocabulary is in `internal/learn`.

## Catalogue

Add every page to `README.md` exactly once, under its group. One line each: the title as a link, then " — " and what it does for you.
