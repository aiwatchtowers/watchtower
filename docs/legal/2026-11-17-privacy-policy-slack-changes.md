# Privacy policy: changes for the Slack Developer Policy (#1769)

The live policy is the site's page `public/privacy/index.html` in the site's own repository (`https://aiwatchtowers.com/privacy/`). Nothing here is applied in this repository: the owner pastes each block below into the section it names, replaces the old sentence where one is given, and deploys the site. The behaviour described is what Watchtower does after #1769 (spec `docs/superpowers/specs/2026-11-17-slack-policy-hygiene-design.md`, section 7).

## Check before pasting

- The provider setting names quoted in item 3 are still what the providers show: Claude "Help improve Claude" and ChatGPT "Improve the model for everyone".
- The provider names and the "Use reserve when limits are reached" wording match the app's Settings → System → AI.

## 1. New section "Slack", after "What we collect"

Old text: none (new section).

New text:

> **Slack.** When you connect a Slack workspace, Watchtower reads, through an app created in your own workspace from Watchtower's manifest, the messages, threads, channels, direct messages and group direct messages you can see, people's names and email addresses, files shared with you, your own reactions, and the workspace's name and custom emoji. It keeps this on your Mac. Watchtower asks Slack for these permissions and no others:
>
> - read the history and the list of public channels, private channels, direct messages and group direct messages, and search: to keep a copy on your Mac;
> - open a direct message and post a message: only when you press Approve on a message you reviewed;
> - read people's names and email addresses: to match them with your calendar, Jira and Linear;
> - read files: to describe images you were sent;
> - read your reactions: for reaction commands;
> - read the workspace's name and custom emoji: to show them.
>
> Watchtower has no server and sends this data to no one but the AI provider you choose, and to your own Claude or ChatGPT account if you turn its Slack connector on (see "AI providers" and "Live Slack").

## 2. "Where your data lives"

Old sentence (replace the sentence about deletion or retention, if there is one; otherwise add it at the end of the section): any sentence saying that data stays on your Mac until you delete it, or that Watchtower deletes data only when you ask.

New text:

> Watchtower has a setting, **Delete an account's data when its access ends**, on by default. While it is on, a workspace's synced Slack data is deleted 72 hours after Watchtower notices that its Slack app was removed, your access was revoked, or you removed the workspace in Watchtower, and you get a notice first; Watchtower notices on its next sync, so a Mac that is off or offline deletes after it is back. If you turn the setting off, or your organization's policy turns it off, the data stays on your Mac until you delete it yourself (Settings → System → **Reset All Data…**, or uninstalling with its data).

Optional sentence right after it, true only when the setting was turned on explicitly (by you or your organization), not by the default:

> When it is turned on explicitly, it also covers a workspace Watchtower has not been able to reach for 30 days.

## 3. "AI providers" section

Old text: the sentence "Watchtower requests only the permissions it needs to function — read-only for Gmail and Google Calendar, nothing more" must not stand as the only statement about permissions (Slack has write permissions behind Approve); replace it with the text below and keep the Gmail and Calendar read-only sentence only next to the Google section.

New text:

> To write summaries and answer your questions, Watchtower sends the message text the feature needs to the AI provider you choose: Anthropic (Claude), OpenAI (Codex), or a model you run yourself (Ollama), which is on your Mac unless you point Watchtower at another server, in which case the data goes where you point it. When image description is on, images shared in Slack are downloaded and sent to the model as well. If you turn on **Use reserve when limits are reached**, a request can go to the other provider (Claude or Codex) when the first one's limit is reached. The text goes under your own account with that provider, and that provider's own terms govern how long it keeps it and where. Watchtower never trains a model on your data. Whether a provider may train on what it receives is a setting in your account with that provider (Claude: "Help improve Claude"; ChatGPT: "Improve the model for everyone"); turn it off there. Watchtower cannot read that setting. AI output can be inaccurate.

## 4. No AI training, for the desktop app

Old text: today only the iPhone section has a no-training line.

New text, in the desktop app's section as well:

> Watchtower never trains a model on your data, and neither does any service of ours: we have none that receives it.

## 5. Live Slack through your own Claude or ChatGPT connector

Old text: none.

New text:

> If you turn on the Slack connector in your own Claude or ChatGPT account, the assistant in Watchtower's chat can ask it for Slack content Watchtower has not synced. The answer stays in that chat on your Mac. The connector is the provider's own app and runs under the provider's terms.

## 6. Pages published to claude.ai

Old text: none.

New text:

> When you publish a page from a chat to claude.ai, it goes to your Claude account and is private by default.

## 7. Derived text that is kept (P9)

Old text: none.

New text:

> Briefings, Catch-Up recaps, ideas, memory notes, chats, automation outputs and meeting transcripts can mix several sources. They are kept when a source's data is deleted, until you delete them yourself.

## 8. Encryption

Old text: the sentence about how stored data is protected, if it names an encryption method.

New text (until database encryption ships):

> Watchtower's files on your Mac are protected at rest by macOS FileVault when it is on, and Watchtower says so when it is off.

When database encryption ships, replace the sentence with: "The database is encrypted with a key held in this Mac's Keychain." (not for pasting now).

## 9. People insights

Old text: any sentence about analysing colleagues, activity or communication patterns.

New text:

> Watchtower writes short notes about colleagues you work with directly, only from work messages: what they work on, their role in decisions and how best to work with them. It never scores, monitors or judges anyone, and you can stop the note for any person.

## 10. "Your rights and control"

Old text: none.

New text, two list items:

> - Remove a Slack workspace in Watchtower and, while **Delete an account's data when its access ends** is on (the default), its data is deleted: the deletion is scheduled with at least 72 hours' notice from Watchtower's next pass.
> - **Reset All Data…** in Settings → System deletes everything Watchtower keeps on your Mac.

## 11. "Last updated" and the release note

Old text: the current "Last updated" date.

New text: set the date to the day the page is deployed, and add one line to the release notes: "Privacy policy: Slack permissions explained, AI providers named, deletion when access ends, no training, people notes."
