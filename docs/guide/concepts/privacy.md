# Privacy

Watchtower has no account, no cloud service and no analytics of its own. Three things leave your Mac: requests to the sources you connect, the text sent to your AI provider, and, only if you turn it on, encrypted data for your iPhone through your own iCloud. This page answers each in turn.

## What stays on your Mac

- **All synced data and AI results.** The database lives in `~/.local/share/watchtower/<workspace>/watchtower.db`, next to Memory's notes and the search index. Meeting recordings are in `~/Library/Application Support/Watchtower/recordings`.
- **Sign-ins.** OAuth tokens for Slack, Google, Jira and Linear are stored as separate files in that folder, readable only by your user. Quick Connection secrets are the same.
- **Meeting transcription.** Audio is captured and transcribed on the Mac. The speech models are downloaded once, on first use, then run locally. Recording audio is deleted after 30 days (**Settings → Meetings → Delete audio after N days**); transcript text is kept.
- **Search.** Knowledge search is a local index and uses no AI.
- **Mechanical features.** Attention detection and Claude plan limits make no AI calls.

Removing an account deletes its sign-in file.

In **Settings → System**, **Reset & Regenerate…** deletes the AI-generated data (raw Slack data, config and profile stay) and **Reset All Data…** removes the config, the database folder, preferences and caches, then quits.

Reset All Data leaves your meeting recordings in `~/Library/Application Support/Watchtower/recordings`, the iPhone-sync folder next to them (`MobileHub`), the sync keys in your Keychain and anything already in iCloud. Delete the recordings by hand. To clear iPhone data, turn off **Sync with iPhone** and remove the phone before you reset.

## What goes to your AI provider

Every AI feature sends the relevant text to the provider you chose in [AI providers, models and cost](ai-providers-and-cost.md), and it arrives under the terms of your own Claude, Codex or other account. Watchtower does not control that provider's retention.

- **Digests, tracks, people and rollups:** message text of the channels that are not muted for AI.
- **Mail and Jira digests:** the text of new mail and changed issues and comments.
- **Briefing, day plan, Catch Up:** your calendar, targets, digests and attention items.
- **Meeting recaps and the meeting chat:** the transcript.
- **AI Chat:** your question plus whatever the assistant reads to answer it, such as messages, mail, tickets or memory notes. It reads them through Watchtower's local tools, and what a tool returns is sent to the provider.
- **Automations:** a confirmed automation sends data to the provider on its own schedule whenever its recipe calls `llm()` or `agent()`.
- **Workbench sessions:** run by Claude Code or Codex in your folder, so they go to that agent's provider. Anything that agent reads or writes is its provider's concern.

With **Ollama / Local** on a server on your own machine, the text never leaves it. Point it at a remote server and it goes there.

**Mute for AI** in Statistics keeps a channel out of digests, tracks and the briefing. It does not stop the chat, Catch Up or Memory from reading it. To stop a kind of data going to the provider, switch the feature off in **Settings → Features**; an off feature sends nothing.

Slack is read-only. The assistant sends or edits something only after you approve it, unless you gave a confirmed automation an automatic grant for that action. A Quick Connection (an outside tool server you add) receives what the assistant sends it when you use it in chat, and what a confirmed automation sends it through `mcp()` on its schedule.

Other network traffic: calls to each source's own service, a version check against GitHub every 6 hours, and a read of your Claude plan limits from Anthropic using Claude Code's sign-in.

## What goes to iCloud

Nothing, unless you turn on **Sync with iPhone** in **Settings → Mobile**. It is off by default.

When it is on, your Mac publishes a trimmed view of its data to your own iCloud (CloudKit) for your iPhone app: Workbench boards with their targets and comments, sessions and their reports, asks, calendar events, meeting transcripts and recaps, and the status of phone recordings (never tokens). The phone sends back actions and recordings.

It is end-to-end encrypted.

Records are sealed with keys held only by your Mac and your paired phones, so iCloud holds ciphertext. A few payload-free alert signals are the exception.

A phone pairs only after you confirm it on the Mac with a four-digit code. An iPhone on another Apple ID joins through shares your Mac creates. **Unlink** or **Forget** on the phone (Settings → Macs) deletes that Mac's data from the phone. Removing the phone on the Mac freezes it there: what it already synced stays readable until you tap **Forget**.

## When something is deleted at the source

A message, mail or comment you delete at its source disappears from Watchtower too, and from search.

- **Slack:** a message deleted today disappears within a sync cycle or two (the newest two hours are not checked yet). Older days are checked one stored day per sync cycle, so a deletion in an older message can take longer to show. If Slack still returns the message later, it comes back.
- **Gmail:** mail you delete or trash disappears within a day. Archived mail stays.
- **IMAP:** mail you delete or move out of the synced folder disappears on the next sync.
- **Jira:** a deleted comment disappears the next time that issue is synced.

Summaries, memory notes, ideas and briefings already written from the text are kept as they are. A safety check skips a deletion when the source returns an empty or suspiciously short list, so nothing vanishes because of a bad response.

## Related

- [Sources and accounts](sources-and-accounts.md)
- [Features: iPhone](../features/iphone.md)
- [Meeting recording](../features/meeting-recording.md)

For developers: [docs/features/mobile-companion.md](../../features/mobile-companion.md)
