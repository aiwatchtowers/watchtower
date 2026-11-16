# How an automation's card looks

An automation can leave a laid-out card in your [Inbox](inbox.md): a row of figures on top, a list of threads with coloured badges, a table, a person, buttons. You say in words how it should look, and the editor's **Look** step draws the card from a dry run on your own data before you save.

## Why use it

A Markdown card is fine for a paragraph. A card that answers "what is waiting for me" reads faster as a count on top and one row per thread, the old ones in red. Seeing it drawn on your data before you save means no guessing what the next run will leave.

## How it works

The recipe's script builds the card from **blocks**: headings, text, lists, tables, a person, a row of figures, links and button rows. Watchtower checks every block when the run writes the card; a block it doesn't know fails the run with an error that names the place. The script decides every colour and order itself, so a recipe can make old rows red without the assistant's help.

A card with blocks also keeps a plain-text copy, so search, Home and copying keep working.

### Cards that stay current
<!-- learn
id: card-look-living
title: Keep one card up to date
text: Ask for a card that stays current: each run updates the same Inbox card instead of filing a new one.
area: automations
level: power
kind: tip
since: 0.28.0
action: nav:automations
-->

Most automations file a new card on every run. A **living** automation (`artifacts: living` in the recipe, with `concurrency: 1`) keeps one card per key and updates it in place: "Waiting for me" stays one card, kept current. In the draft column, **When it runs** has an **Inbox cards** box: **One card per key, kept current** for such a recipe, **A new card each run** otherwise.

- A living card moves up the Inbox and turns unread only when its content changed; the line under it reads **Updated 10 min ago**.
- **Done** and **Dismiss** apply to what you saw: when the content changes, the card comes back.
- A run that rewrites the same content keeps the card read, done or dismissed and in its place; only **Updated** moves.
- A living automation runs one run at a time.

## Using it

### Change the look in the editor
<!-- learn
id: card-look-step
title: See the card before you save
text: In the automation editor, open **Look** and tell the assistant how the card should look; it draws it from your data.
area: automations
level: next
kind: feature
since: 0.28.0
action: nav:automations
-->

1. Open the automation and press **Edit**, or click **+** for a new one.
2. In the draft column, pick **Look** in the step picker (**What it collects · Look · When it runs**).
3. Tell the assistant in **Chat** what you want: "a count of open threads on top, then the threads, oldest first, red after a day". After each change it dry-runs the draft, and **Look** draws the result.
4. Press **Dry run** to draw it yourself, for example after an edit in **Script**. It reads your data and writes nothing; its tokens are your spend.
5. With several cards, pick one from the **Card 1 of 4 — <title>** menu.
6. Press **Save Look**. It is the same save as on the other steps: it confirms everything the column lists.

Buttons in the preview are drawn but don't work (**Buttons work in the Inbox**); links open.

### When a change adds an AI step

When your change gives the recipe a new `llm()` step, the footer says **This change adds an AI step: every run will use the model.** above the save button, on every step. When a dry run of this text exists, it adds how many tokens it used. Prefer a look the script can compute; ask for an AI step only when the card needs one.

## When it's empty or wrong

- **"This automation doesn't make an Inbox card."** The recipe has no Inbox output. Ask the chat to put its result in the Inbox.
- **"Dry-run the recipe to see its card on your data."** Nothing was dry-run yet. Press **Dry run**.
- **"The recipe changed since this preview."** The text moved on after the last dry run; the old card is dimmed. Press **Dry run**, or ask the assistant for the change again.
- **"This dry run made no card — it found nothing to show."** The recipe ran but found nothing. Try again when there is data, or ask the assistant to show an empty state.
- **The dry run failed.** The error and **Last steps** say where. An error in `output.inbox` names the block, for example `blocks[2].rows[0] has 4 cells; the table has 3 columns`. Ask the assistant to fix it.
- **"The dry run stopped at a Quick Connection".** A draft doesn't call Quick Connections. Save it and use **Dry Run** on its card to see the rest.
- **"This card needs a newer Watchtower"** in the Inbox. The card was written in a newer format; update the app. Its plain text is shown meanwhile.
- **"This card's layout can't be read".** The stored layout is damaged; its plain text is shown instead.
- **"This card changed — look again"** after a button press. A living card was updated while you looked at it; nothing was sent. Press the button on the updated card.

## Reference: blocks

| Block | What it draws |
|---|---|
| `heading` | A heading, level 1 or 2 |
| `text` | Markdown, with the chat's link rules; images aren't loaded |
| `list` | Rows with a title, subtitle, badge, coloured dot, link and up to 3 buttons; its `empty` text shows when no row is left |
| `table` | Up to 6 columns and 100 rows |
| `person` | A name, role, avatar from your Slack users (initials otherwise) and up to 10 lines |
| `metrics` | One row of up to 6 figures |
| `link` | A row that opens a page |
| `actions` | A row of up to 4 buttons |

- Colours are a `tone`: `neutral`, `info`, `success`, `warning`, `danger` or `accent`.
- A card holds at most 40 blocks, 500 list and table rows, 50 buttons and 128 KB.
- Blocks don't nest, and a card never loads an image from the web.
- Buttons in blocks are the same kinds as the card's own: see [Buttons on automation cards](automations-inbox-buttons.md).

## Related

- [Automations](automations.md)
- [Buttons on automation cards](automations-inbox-buttons.md)
- [Automations: recipes and templates](automations-recipes.md)

For developers: [docs/features/inbox-card-blocks.md](../../features/inbox-card-blocks.md)
