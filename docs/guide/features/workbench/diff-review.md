# Branch review

Branch review lets you read what an agent session changed, comment on lines, and send your comments back to the agent as one round. You use it when a session says it is done and you want to check the code, not the story.

## Why use it

A pull request review needs a pull request. Here you review before anything is committed, and the agent reads your comments by itself. The next round shows only what changed since, and keeps your Viewed marks for files that did not move.

## How it works

**Review** on a session's strip, or **Review Branch** in its row menu, opens the **Branch review** pane and starts a round. At the top, an identity bar names the branch and its base (`feature/x → main`), the files and lines changed, the uncommitted edits, the worktree the session works in, and the targets the work is for. Watchtower snapshots the folder's working tree (tracked and untracked files, not ignored ones) and compares it with a base, the point where the branch left the default branch. The snapshot only writes git objects. It touches no branch, no index and no file.

The pane has a file list, a diff, and a list of comments. Files show added, modified, deleted or renamed, their line counts and a **Viewed** checkbox. Lockfiles, generated files and very large files are folded by name. Binary and oversized files show a placeholder.

A round moves through three states: you collect drafts, **Send review** stores the round, and the agent reads it with its `get_review` tool, which marks it delivered. Watchtower then puts one line into the session, `Review round #N sent (n comments) — read it with get_review N using the watchtower-workbench skill.`. The agent sees your comment text, the quoted lines and where each sits.

### The AI overview

The AI overview is a short summary of the round: whether the changes cover the linked targets, which files fall outside them, a risk mark per file and a reading order. Each overview is one call to the strong model, saved per snapshot, so reopening the same snapshot costs nothing. The **Quick** / **Deep** switch in the toolbar decides when it runs:

- **Deep** makes it by itself when the round opens and whenever **Refresh** finds new changes.
- **Quick** shows a saved overview at once, and otherwise offers **Make overview**. Until you press it, files are grouped by the agent's chapters or by folder.
- When **Refresh** finds new changes in **Quick** and nothing is saved for them, the old risk marks and reading order go away and **Make overview** comes back. An overview you asked for keeps running through a refresh; if the changes moved meanwhile, it shows as being for an earlier version.

If it fails, the reason shows with **Retry**, and the review works without it.

### Deep phases

**Deep** walks three phases: **1 Meaning**, **2 Chapters**, **3 Wrap-up**. **Next: Chapters** sits at the foot of Meaning and **Next: Wrap-up** at the foot of Chapters. Wrap-up has no Send of its own; use **Send review** in the toolbar.

- **Meaning** shows what the linked targets ask for and your **Design comments**: remarks on the whole change, not on a line, added with **Add design comment…**.
- **Chapters** groups the files by folder, at most 400 changed lines each. When the AI overview has chapters, **Use them** switches to those. Each chapter has a checklist per lens; **Comment…** on a question turns it into a comment.
- **Wrap-up** asks **Was the intent met?** per linked target. **Partly** and **Not done** add a comment for the agent.

### Lenses and house rules

A lens is a set of review questions: **Correctness**, **Tests**, **Security**, **Simplicity** and **House rules**. Add your own in `.watchtower/review.md` in the workbench folder: `## Name` starts a lens, `- question` adds a question. The agent reads the same file before it hands work back.

**Find Repeats…** in the toolbar's **More** menu (…) looks through your comments of the last 20 sent rounds for remarks you keep making, in one call to the strong model. **Accept** writes a proposed rule into `.watchtower/review.md` under its lens; **Dismiss** drops it. **More** also has **Show in Finder** and **Open in Terminal**.

### What the agent sends back

The agent can leave notes, shown in the diff and under **The agent's walkthrough**. It answers your comments; a reply shows as **Agent:** under the comment. Comments it fixed move to **Resolved by the agent**; **Reopen** puts one back for the next round.

### Undo a hunk

**Undo** on a hunk in the diff reverts those lines in the folder at once, with no confirmation, and lists them under **Undone**. The agent is told and does not redo them without asking. Undo is off once the round is sent and while the agent works; binary, symlinked and very large files cannot be undone.

### Next rounds

After a send, the toolbar offers **Start next round** (the same as **Refresh**). The view switch then offers **All changes** and **Since round N**. Comments not yet resolved are carried to the new round and follow their quoted lines when the code moved. A comment whose lines are gone stays, marked outdated. A file keeps its **Viewed** mark while its content and mode are unchanged.

## Using it

1. Press **Review** on the session's strip, or choose **Review Branch** in a session's row menu.
2. Click a file. Read the diff. **Inline** switches to one column.
3. To comment, select lines, right-click and choose **Comment**, type your note and press **Add**. Comments on the removed side are allowed in the **All changes** view.
4. Tick **Viewed** on files you have read. ⌥⌘↑ and ⌥⌘↓ jump to the previous and next unviewed file.
5. **Send review (n)**. A banner tells you what happened to the line: "Line pasted — press Return in the terminal", "Will be sent when the agent's turn ends", or "Copied — paste it into the terminal".

A draft has **Delete**. A carried comment has **Edit** and **Resolve**, and an outdated one has **Resolve**. Resolved comments are not carried again.

## When it's empty or wrong

- **"Nothing to review".** The folder matches the base. Make or wait for edits, then **Refresh**. No overview is made for an empty round.
- **"Nothing new since round N".** The **Since** view found no change after that send.
- **"On main — only uncommitted edits are reviewed".** The session works on main or master with nothing committed past it, so only its uncommitted edits are in the round.
- **The Review button is not there.** It shows on an agent session's strip when that session has uncommitted edits or unpushed commits, works on a branch other than main or master, or is on a detached HEAD, and while its pane is open. Use **Review Branch** in the row menu otherwise; a **Ready to check** session also has it on hover and in its report.
- **"Round N's snapshot is gone — showing all changes".** Git pruned the old snapshot. You lose only the **Since round** view.
- **"The diff is too large; later files show without hunks".** The diff hit its size limit. Open those files in the [code viewer](code-viewer.md).
- **"Undo is off while the agent is working".** Wait until the session stops, then **Undo**. **"Round already sent"** means **Start next round** first.
- **"This round was already sent".** Press **Refresh** to open the next round.
- **Files tracked by Git LFS show a pointer or raw bytes.** Filters are switched off while reading.

## Related

- [Sessions](sessions.md) and [Asks](asks.md): a review ask is another way to ask for your eyes.
- [Workbench](README.md)

For developers: [docs/features/diff-reviewer.md](../../../features/diff-reviewer.md)
