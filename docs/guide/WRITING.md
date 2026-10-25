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
