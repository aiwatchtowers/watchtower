# Artifacts in the AI Chat

When the assistant writes something you will copy, send or keep, such as a document, table, email or Slack draft, event, code or an HTML page, it opens in the artifact panel instead of the chat. This page is for anyone working with those drafts in the [AI Chat](ai-chat.md).

## Why use it

You ask for a follow-up email after a meeting. The draft lands in the panel, you comment on one sentence, the assistant revises it, and **Open in Gmail** gives you the ready compose window.

## How it works

Each change is a new version of the same artifact; the earlier ones stay. Drafts are never sent by Watchtower: you send, post or schedule them yourself. An HTML page runs with no internet access, so links in it open nothing.

## Using it

### Artifacts

A document, table, email or Slack draft, event, code or HTML page opens in the artifact panel instead of the chat. Each change is a new version; you can edit it, copy it, or export it to a file (the extension follows the kind, for example .md, .csv or a language's extension for code).

Select a passage and choose **Comment** to leave a note. Notes stay drafts until you click **Send N comments**, which sends them together; the assistant answers with a new version.

An HTML page, such as a slide deck, shows rendered in the panel once it is fully written. Click the page, then use the arrow keys to page through a deck. **Present** opens it full screen (Esc leaves), **Open in Window** opens a big window, and **Reload** starts it over. The page runs with no internet access at all, so ask for one self-contained file, and links in it open nothing. It stays in Watchtower: there is no browser button, because a page written from your synced messages must not be able to send them anywhere. To keep or share it, use **Export…** to save the `.html` file. HTML pages take no passage comments.

Drafts are never sent by Watchtower. An email opens in Gmail compose (**Open in Gmail**) or **Open in Mail**, a Slack draft is copied with its channel opened, and an event opens Google Calendar's new-event page.

## When it's empty or wrong

- **An HTML page shows nothing yet.** It renders once it is fully written.
- **A page loads no images or styles.** It runs with every network load blocked; ask for one self-contained file.
- **No passage comments on an HTML page.** HTML pages take none; ask for the change in the chat.

## Related

- [AI Chat](ai-chat.md)
- [Writing and changing things from the AI Chat](ai-chat-actions.md)

For developers: [docs/features/chat-redesign.md](../../features/chat-redesign.md)
