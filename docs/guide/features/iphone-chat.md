# iPhone: AI chat

The Watchtower iPhone app has a **Chats** tab: the same conversations as AI Chat on your Mac, with the same answers, steps, approvals and artifacts. You can ask from the phone, and a question you started on the phone is answered by your tower. It is for anyone who already linked a phone (see [iPhone](iphone.md)).

## Why use it
<!-- learn: none -->

You think of a question away from your desk: "what did the vendor say about renewal?" The phone asks your Mac, which has your Slack, mail and Jira, and the answer comes back to the same chat you will find on the Mac later.

## Availability
<!-- learn: none -->

Chat on the phone needs Relay. Relay isn't in the current version of Watchtower for iPhone.

Until then the **Chats** tab explains what is missing, for example **Chat works over Relay**, with **Switch to Relay…**. With iCloud as the transport, chat stays on the Mac. Chat also needs the Mac's chat permission for this phone, which is on by default, and an up-to-date Watchtower on the Mac (**Update Watchtower on your Mac** otherwise). If your organization limits what phones may read, the tab says **Chat is turned off by your organization**.

## How it works
<!-- learn: none -->

Your phone never talks to an AI provider. It sends your message to your tower, the tower runs it with your provider (up to three chats at once, shared with the Mac) and writes the answer into the same chats the Mac shows. The phone shows the answer as it grows and keeps a copy of the chats you opened, so you can read them when the Mac is asleep.

One answer runs per chat at a time, and it streams live on both devices whichever one started it; **Stop** works from either. Pressing Send while the other device's answer is running keeps your text in the field. An answer keeps running when the Mac's background service restarts, and ends when you quit Watchtower on the Mac.

When an answer is ready, a chat you are not looking at sends a notification (**Answer ready**, **The answer stopped**, or **Waiting for your approval**), only while you are away from the Mac. It never shows the answer text. Tap it to open the chat.

## Using it

### Read and find chats
<!-- learn: none -->

The list is Pinned, then Recent (7 days), then **N older**. A dot shows the state: orange waits for your approval, blue is answering, filled means a new answer. Typing in the search field filters by title at once and, a moment later, shows matches inside messages from your Mac under **In messages**; offline it shows titles only. Swipe or touch and hold a row for **Pin**, **Rename** or **Delete**; Delete hides the row for 5 seconds with **Undo** and only then deletes it.

Opening a chat loads its newest 60 messages; **Load earlier messages** brings older ones, so a whole chat is readable. The twenty most recent chats are fetched in the background while the app is open and reachable, and stay readable offline.

### Ask something
<!-- learn: none -->

**✎** starts a chat. Above the field, the project chip can be changed until the first message. **@** mentions a person, channel or issue and **/** picks a skill; both show as chips above the field. **+** attaches a photo, a picture from your library or a file (images up to 5 MB, PDF up to 32 MB, text up to 256 KB, 30 MB per message; a large photo is made smaller first). Send becomes **Stop** while an answer runs, whoever runs it.

Touch and hold your own message for **Edit**. On the last answer, **Regenerate** and the **‹ 1/2 ›** arrows move between versions. Touch and hold a finished answer for **Ask about this**, choose a passage in the sheet, and it waits above the field with a **Comment (optional)** line, then rides along with your next message. Nothing is sent or queued while the Mac is offline: the field and buttons turn off, and your text stays in the field.

### Choose the model
<!-- learn: none -->

The model pill above the field works as on the Mac, and you can change it between answers in any chat. **Preferred + reserve · Auto** lets your tower move to the reserve provider when the preferred one reaches its limit; **Only Claude · <model>** keeps the chat on one provider. A chat that moved shows **Current provider:** above the pill and a card saying why; once the preferred provider can be tried, the card offers **Use Claude** (your preferred provider's name) for the next answer. The list holds the models your Mac knows, and availability updates when your chats change.

### Approve what the assistant wants to do
<!-- learn: none -->

When the assistant proposes a write (a Slack message, a Jira comment), the answer shows an orange card with what it will do, **Approve** and **Reject**. Approving needs the permission to **Answer permission prompts from this phone** on the Mac; without it the card says **Approve on the Mac**. If the action changed since the phone showed it, you see **The action changed — look again** and decide again. The card is the one the Mac shows: who a Slack message goes to, a Jira issue's fields, the changes to a Confluence page, a connector's input, and the result once it ran. A Slack message with no workspace chosen yet says **Choose a workspace on** your Mac and offers only Reject. A Confluence edit too long for the phone says so; approving it runs exactly what your Mac stored. Editing first, choosing a workspace, **Approve all**, **Retry** and **Dismiss** stay on the Mac.

### Artifacts and sources
<!-- learn: none -->

An artifact card opens a sheet: documents, tables and code as text, **Open in Mail** for an email, **Open in Google Calendar** for an event, **Copy & open Slack** for a Slack post, a sandboxed page for HTML. The sheet only opens and copies; nothing is sent from it. **Sources** lists what the answer used, grouped as on the Mac.

## When it's empty or wrong
<!-- learn: none -->

- **The Mac did not answer.** The phone waited 30 seconds (it also happens when Watchtower's background service on the Mac is stopped); **Retry**, or check the Mac is awake (see [The iPhone is not syncing](../troubleshooting/iphone-not-syncing.md)).
- **No Chat switch or the tab says it is not allowed.** On the Mac, Settings → **Mobile** → the phone's **Chat** switch.
- **Older conversations are missing offline.** Only chats you opened or that were fetched in the background, and only the pages you loaded, are kept; search inside messages needs the Mac.
- **"Saved chats are off on this phone".** The phone could not open its saved copy of your chats. The tab still works while the Mac answers, but nothing is kept for offline reading and a message still on its way is lost if the app restarts. Restarting the app tries again.

## Related

- [iPhone](iphone.md) and [iPhone: Relay](iphone-relay.md)
- [AI chat](ai-chat.md)
