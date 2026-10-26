# Privacy

Watchtower has no account, no cloud service and no analytics of its own. Three things leave your Mac: requests to the sources you connect (and to the public pages their links point to), the text sent to your AI provider, and, only if you turn it on, encrypted data for your iPhone through your own iCloud. This page answers each in turn.

## What stays on your Mac

- **All synced data and AI results.** The database lives in `~/.local/share/watchtower/<workspace>/watchtower.db`, next to Memory's notes and the search index. Meeting recordings are in `~/Library/Application Support/Watchtower/recordings`.
- **Sign-ins.** OAuth tokens for Slack, Google, Jira and Linear are stored as separate files in that folder, readable only by your user. Quick Connection secrets are the same.
- **Meeting transcription.** Audio is captured and transcribed on the Mac. The speech models are downloaded once, on first use, then run locally. Recording audio is deleted after 30 days (**Settings → Meetings → Delete audio after N days**); transcript text is kept.
- **Knowledge search.** The index is local; only its image descriptions and link summaries use AI (below).
- **Mechanical features.** Attention detection and Claude plan limits make no AI calls.

Removing an account deletes its sign-in file. With **Delete an account's data when its access is revoked** on, a revoked account's synced data is deleted after a 72-hour notice, and so is a source's that Watchtower has not reached for 30 days: see [Revoked access deletes an account's data](revoked-access.md).

In **Settings → System**, **Reset & Regenerate…** deletes the AI-generated data (raw Slack data, config and profile stay) and **Reset All Data…** removes the config, the database folder, preferences and caches, then quits.

Reset All Data leaves your meeting recordings in `~/Library/Application Support/Watchtower/recordings`, the iPhone-sync folder next to them (`MobileHub`), the sync keys in your Keychain and anything already in iCloud. Delete the recordings by hand. To clear iPhone data, turn off **Sync with iPhone** and remove the phone before you reset.

## Watchtower stays out of Time Machine
<!-- learn
id: privacy-time-machine
title: Your data stays out of Time Machine
text: Time Machine skips Watchtower's data folders; backups made earlier still hold them, so delete those copies.
area: setup
level: next
kind: tip
since: 0.25.0
-->

Time Machine skips two folders: `~/.local/share/watchtower` (the database, Memory, logs, sign-ins) and `~/Library/Application Support/Watchtower` (recordings, iPhone sync). The app marks them again at every launch and daemon start. `~/.config/watchtower` is still backed up: mostly settings, though an old config may still hold a Slack token.

Backups made earlier still hold the two folders. To delete those copies:

1. In Finder, press **⌘⇧G** and go to the folder's parent (or press **⌘⇧.** to show hidden folders).
2. Open Time Machine, Control-click the folder and choose **Delete All Backups of "…"**.

An APFS backup disk (the default since macOS 11) has no such item and deletes only whole backups. Find them with `tmutil destinationinfo` and `tmutil listbackups`, then run `sudo tmutil delete -d <disk> -t <timestamp>` (Terminal needs Full Disk Access), or erase the disk and back up again.

If a folder sits on a disk that cannot hold the flag (exFAT, a network share), Time Machine still backs it up; `watchtower logs` shows a `backup exclusion:` line.

Other backup tools may ignore Time Machine's flag: exclude the two folders there by hand.

## What Watchtower keeps outside its database

Most of what Watchtower knows lives in the database; a few things are files beside it.

- **Logs** name channels, people and meetings by id and record counts and errors, never message text, titles or AI answers. Log files from an earlier version may hold text until they rotate out.
- **AI calls leave no session files.** Watchtower's own Claude and Codex calls write nothing to the agent's history folder; a chat picks up again from its saved messages. Workbench sessions are the agent's own and keep their history.
- **Still files:** meeting recordings, chat attachments, target images, Memory's notes and sign-in files, readable only by your user. FileVault protects them at rest.
- **What you paste into a session's Workchat** is deleted when that session ends.

## What goes to your AI provider

Every AI feature sends the relevant text to the provider you chose in [AI providers, models and cost](ai-providers-and-cost.md), and it arrives under the terms of your own Claude, Codex or other account. Watchtower does not control that provider's retention.

- **Digests, tracks, people and rollups:** message text of the channels that are not muted for AI.
- **Mail and Jira digests:** the text of new mail and changed issues and comments.
- **Briefing, day plan, Catch Up:** your calendar, targets, digests and attention items.
- **Meeting recaps and the meeting chat:** the transcript.
- **Chats:** your question plus whatever the assistant reads to answer it, such as messages, mail, tickets or memory notes. It reads them through Watchtower's local tools, and what a tool returns is sent to the provider.
- **Asking with ⌘/:** the same as Chats, plus a short note on the tab you are on, its empty-state status line and the selected item's title. The note is sent with that message only and is not stored.
- **Automations:** a confirmed automation sends data to the provider on its own schedule whenever its recipe calls `llm()` or `agent()`.
- **Knowledge search:** new images (strong model) and the text of public pages that synced Slack or Confluence links point to (light model). See [Images and links](../features/search-and-knowledge.md#images-and-links).
- **Workbench sessions:** run by Claude Code or Codex in your folder, so they go to that agent's provider. Anything that agent reads or writes is its provider's concern.

With **Ollama / Local** on a server on your own machine, the text never leaves it. Point it at a remote server and it goes there.

**Mute for AI** in Statistics keeps a channel out of digests, tracks and the briefing. It does not stop the chat, Catch Up or Memory from reading it. To stop a kind of data going to the provider, switch the feature off in **Settings → Features**; an off feature sends nothing.

Slack is read-only. The assistant sends or edits something only after you approve it, unless you gave a confirmed automation an automatic grant for that action. A Quick Connection (an outside tool server you add) receives what the assistant sends it when you use it in chat, and what a confirmed automation sends it through `mcp()` on its schedule.

Other network traffic: calls to each source's own service, Knowledge search opening public links like a browser visit (the site sees your Mac's address; a tracking link can tell its author), a version check against GitHub every 6 hours, and a read of your Claude plan limits from Anthropic using Claude Code's sign-in.

## What goes to iCloud
<!-- learn
id: privacy-iphone-encrypted
title: iPhone sync is end-to-end encrypted
text: **Sync with iPhone** goes through your own iCloud, sealed with keys only your Mac and paired phones hold.
area: iphone
level: next
kind: feature
since: 0.24.0
-->

Nothing, unless you turn on **Sync with iPhone** in **Settings → Mobile**. It is off by default.

When it is on, your Mac publishes a trimmed view of its data to your own iCloud (CloudKit) for your iPhone app: Workbench boards with their targets and comments, sessions and their reports, asks, a session's chat (only while the phone has it open), calendar events, meeting transcripts and recaps, and the status of phone recordings (never tokens). The phone sends back actions and recordings.

It is end-to-end encrypted.

Records are sealed with keys held only by your Mac and your paired phones, so iCloud holds ciphertext. A few payload-free alert signals are the exception.

A phone pairs only after you confirm it on the Mac with a four-digit code. An iPhone on another Apple ID joins through shares your Mac creates. **Unlink** or **Forget** on the phone (Settings → Macs) deletes that Mac's data from the phone. Removing the phone on the Mac freezes it there: what it already synced stays readable until you tap **Forget**.

## How much an assistant can read in one session
<!-- learn
id: privacy-read-limit
title: Start fresh after the read limit
text: An assistant reads at most 300 times or 5,000 rows per session; past that, start a new chat or session.
area: assistant
level: power
kind: tip
since: 0.25.0
-->
<!-- learn
id: privacy-audit-log
title: Audit what assistants read
text: Every read leaves one content-free line in the Mac's system log, under `com.watchtower.audit`.
area: setup
level: power
kind: feature
since: 0.25.0
-->

An assistant can read your synced data at most 300 times, or 5,000 rows, in one session. One read returns at most 256 KB, and a list at most 200 rows. The limit holds for the main chat, workbench agents, automation runs and any app connected to `watchtower mcp`. Past it the read is refused with **this session's read limit is reached (300 calls / 5000 rows); the owner can start a new session**; a new chat, session or run starts a fresh count. A chat built into a screen counts per message, and each `watchtower tools call` on its own. Your own board, asks and skills do not count.

Every such read leaves one line in the Mac's system log: the tool, the session and the row count, never the text. Your company's security tools can collect it; to look yourself, run `log show --last 1h --predicate 'subsystem == "com.watchtower.audit"'`. The system keeps it a few days, and Watchtower sends it nowhere. A `watchtower` command an agent runs in a workbench terminal or an automation that prints your data (`digest`, `inbox`, `kb search`, …) leaves a line too, without a limit.

## When something is deleted at the source
<!-- learn
id: privacy-source-deletions
title: Deleted at the source, gone here
text: Delete a Slack message, mail or Jira comment at its source and Watchtower removes it too, search included.
area: setup
level: next
kind: feature
since: 0.24.0
-->

A message, mail, comment or Jira issue you delete at its source disappears from Watchtower too, and from search.

- **Slack:** a message deleted today disappears within a sync cycle or two (the newest two hours are not checked yet). Older days are checked one stored day per sync cycle, so a deletion in an older message can take longer to show. If Slack still returns the message later, it comes back.
- **Gmail:** mail you delete or trash disappears within a day. Archived mail stays.
- **IMAP:** mail you delete or move out of the synced folder disappears on the next sync.
- **Jira:** a deleted comment disappears the next time that issue is synced. A deleted issue, or one moved to a project you do not sync, disappears within about a day. If you lose access to a single issue, it disappears too; if you lose access to a whole project, its issues stay.

Inbox items made from a deleted message or mail stay, with their text removed. If you leave a Slack channel or lose access to it, its messages stay in Watchtower: only a deletion counts. Summaries, memory notes, ideas and briefings already written from the text are kept as they are. A safety check skips a deletion when the source returns an empty or suspiciously short list, so nothing vanishes because of a bad response.

## When your company manages the Mac

A company's configuration profile can restrict sources, iPhone sync, Quick Connections, AI providers and claude.ai tools. Such controls show **Managed by your organization**; nothing is deleted because of a rule. See [Managed by your organization](managed-by-your-organization.md).

## Related

- [Sources and accounts](sources-and-accounts.md)
- [Revoked access deletes an account's data](revoked-access.md)
- [Features: iPhone](../features/iphone.md)
- [Meeting recording](../features/meeting-recording.md)

For developers: [docs/features/mobile-companion.md](../../features/mobile-companion.md)
