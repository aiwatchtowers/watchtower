# Writing the guide

Rules for every page in `docs/guide/`. A user-facing change updates its page in the same PR.

## Rules

1. **Every page is page one.** Give one line of context, then a link instead of "see above".
2. **Every section stands alone.** Headings say what the section answers ("Why the briefing skips a day"). The first sentence carries the answer. Never write "as mentioned".
3. **One kind of text per section.** Why and how it works explain. Using it gives steps. Reference is lists and tables. Troubleshooting is symptom to fix.
4. **Short.** Start from the reader's task and use one real scenario. Paragraphs are three sentences or fewer. A feature page stays under about 8 KB (`wc -c`); split it rather than grow it.
5. **Only what the screen doesn't say.** Keep schedules, preconditions, data sources and what a button really does. Put UI names, error text and shortcuts in **bold**, spelled as the app spells them.
6. **True to the code.** Check every schedule, default, condition, string and shortcut against the Go or Swift source. The code beats other docs.
7. **Only what ships on `main`.** No roadmap, no "coming soon".
8. **Voice.** Second person, present tense, plain words. "The assistant" is the only name for the AI persona.
9. **Public repo.** No real names, ids, domains or paths. Use `acme` and `example.com`.

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

Drop a section that would be empty. Keep the others in this order.

## Troubleshooting page shape

The title is the symptom ("Briefings tab is empty"). Then:

1. What you see, with the exact UI or error text.
2. Why, in one or two sentences.
3. Fix, as ordered steps.
4. How to check it worked.
5. If it didn't, what to try next.

## Catalogue

Add every page to `README.md` exactly once, under its group. One line each: the title as a link, then " — " and what it does for you.
