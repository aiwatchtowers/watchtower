# Branch reviewer

Beside [Branch review](diff-review.md) sits a second assistant: an independent reviewer that reads the branch and answers your questions about it. It is not the agent that wrote the code and never talks to it. This page is for anyone reviewing a large branch who wants a second opinion across its chapters.

## Why use it

A branch touches forty files in six chapters. Before you approve it you want to know what breaks if a provider has no row in the new table, or what adding one more provider would take. The reviewer reads the code and answers with the files and lines it found.

## How it works
<!-- learn
id: diff-review-reviewer
title: Ask a reviewer about a branch
text: Switch Branch review's chat to Reviewer and ask what breaks if something changes. It never talks to the author.
area: development
level: next
kind: feature
since: next
action: nav:projects
-->

The chat panel beside the diff (toolbar button or ⌥⌘C) has a **Reviewer | Author** switch. **Author** is the session's chat, as before; **Ask agent** always switches to it. **Reviewer** is the independent reviewer.

- **What it reads.** Each question comes with a short map of the branch: its chapters with their danger, the summary and the chapter you have open. The reviewer then reads the files itself — in the session's own worktree when the session has one, otherwise in the workbench folder. It only reads; it never changes a file.
- **One thread per branch.** Every session on the same branch shares one reviewer thread. A renamed branch starts a new one.
- **Send to author.** Nothing you discuss reaches the author's session unless you press **Send to author** under an answer. It adds the answer as a design comment to the open round, which goes out with **Request changes** like your other comments. The answer then shows "Sent to the author as a design comment in round N".

## Using it

1. Open **Branch review** for a session and open the chat panel.
2. Switch to **Reviewer** and ask, for example, "What would adding another provider take?"
3. Read the answer; file and line references point into the branch.
4. Press **Send to author** on an answer the agent should act on, then **Request changes** when the round is ready.

## When it's empty or wrong

- **"Start a round to send".** The round was sent or approved. Press **Refresh** to open the next round, then send the answer.
- **An answer failed or timed out.** The reply shows its error; press **Retry**.
- **The answer says it could not read the code.** The configured AI provider cannot read files (Ollama). Switch to Claude or Codex in Settings.

## Related

- [Branch review](diff-review.md)
- [Sessions](sessions.md)
