# Branch review

Branch review lets you read what an agent session changed, comment on lines, and send your comments back to the agent as one round, when a session says it is done.

## Why use it

Here you review before anything is committed, and the agent reads your comments by itself. The next round shows only what changed since, and keeps your Viewed marks for files that did not move.

## How it works
<!-- learn
id: diff-review-start
title: Review what a session changed
text: Press **Review** on a session's strip to read its diff, comment on lines and send them back as one round.
area: development
level: basics
kind: feature
since: 0.24.0
action: nav:projects
-->
<!-- learn
id: diff-review-approve
title: Approve a branch that is done
text: Press **Approve** in Branch review and the agent finishes the branch the way its methodology says.
area: development
level: next
kind: feature
since: next
action: nav:projects
-->
<!-- learn
id: diff-review-file-tree
title: Read the diff by folder
text: Branch review lists files as a folder tree with unviewed counts; open a hidden stretch or **Full file** in place.
area: development
level: next
kind: tip
since: next
action: nav:projects
-->

**Review** on a session's strip, or **Review Branch** in its row menu, opens the **Branch review** pane and starts a round. At the top, an identity bar names the branch and its base (`feature/x → main`), the files and lines changed, the uncommitted edits, the worktree the session works in, and the targets the work is for. Watchtower snapshots the folder's working tree (tracked and untracked files, not ignored ones), writing only git objects, and compares it with a base, the point where the branch left the default branch.

The pane has a file list (a folder tree), a diff, and a list of comments. In the tree a folder shows how many files are unviewed (or **all viewed**) and its open comments. Files show added, modified, deleted or renamed, their line counts and a **Viewed** checkbox. Lockfiles, generated, binary and very large files show folded or as a placeholder.

The diff hides unchanged stretches and keeps three lines of context. Click a hidden stretch to open it, or **Full file** next to the file name for the whole file; **Changes** goes back.

A round moves through three states: you collect drafts, then you close it with one of two verdicts. **Request changes** stores the round, and the agent reads it with its `get_review` tool, which marks it delivered. Watchtower then puts one line into the session telling the agent to read round N with `get_review`.

**Approve** closes the round with no changes requested and tells the agent to finish the branch as its methodology says. It needs no drafts (send or delete them first) and a session that still exists. A popover names what you may have missed: unviewed chapters and Wrap-up items marked **Partly** or **Not done**. If earlier comments are still open, **Resolve N and approve** closes them too. A closed round shows **Approved** with the time.

### The AI overview
<!-- learn
id: diff-review-ai-overview
title: Get an AI overview of the changes
text: Press **Make overview**, or switch to **Deep**, for risks per file, a reading order and target coverage.
area: development
level: next
kind: feature
since: 0.24.0
action: nav:projects
-->

The AI overview is a short summary of the round: whether the changes cover the linked targets, which files fall outside them, a risk mark per file and a reading order. Each overview is one strong-model call, saved per snapshot. The **Quick** / **Deep** switch in the toolbar decides when it runs:

- **Deep** makes it by itself when the round opens and whenever **Refresh** finds new changes.
- **Quick** shows a saved overview at once, and otherwise offers **Make overview**. Until you press it, files are grouped by the agent's chapters or by folder.
- When **Refresh** finds new changes in **Quick** and nothing is saved for them, the old marks go away and **Make overview** comes back.

If it fails, the reason shows with **Retry**. With the finish check on, an agent that changed files makes this overview before it finishes; a round on the same changes shows it at once, with no second call.

### Deep phases
<!-- learn
id: diff-review-chapter-risks
title: See the risks in each chapter
text: In **Deep**, each chapter lists what to look at from the AI overview; turn one into a comment or ask the agent.
area: development
level: power
kind: feature
since: next
action: nav:projects
-->
<!-- learn
id: diff-review-chapter-viewed
title: Finish a chapter with ⌥⌘Return
text: Press **Chapter viewed →** or ⌥⌘Return to mark a chapter's files Viewed and move to the next one.
area: development
level: power
kind: tip
since: next
action: nav:projects
-->

**Deep** walks three phases: **1 Meaning**, **2 Chapters**, **3 Wrap-up**. **Next: Chapters** and **Next: Wrap-up** sit at the foot of the phase before. Wrap-up has no verdict buttons of its own; use **Request changes** or **Approve** in the toolbar.

- **Meaning** shows what the linked targets ask for and your **Design comments**: remarks on the whole change, not on a line, added with **Add design comment…**.
- **Chapters** groups the files by folder, at most 400 changed lines each. When the AI overview has chapters, **Use them** switches to those. Under the diff, **What to look at in this chapter** lists the risks the AI overview names for its files; **Comment…** on one turns it into a design comment, and **Ask agent** sends it to the chat panel. **Chapter viewed →** (⌥⌘Return) marks the chapter's files Viewed and moves to the next chapter that is not.
- **Wrap-up** asks **Was the intent met?** per linked target. **Partly** and **Not done** add a comment for the agent.

### Lenses and house rules

A lens is a set of review questions: **Correctness**, **Tests**, **Security**, **Simplicity** and **House rules**. Add your own in `.watchtower/review.md` in the workbench folder: `## Name` starts a lens, `- question` adds a question.

**Find Repeats…** in the toolbar's **More** menu (…) looks through your comments of the last 20 sent rounds for remarks you keep making. **Accept** writes a proposed rule into `.watchtower/review.md` under its lens; **Dismiss** drops it.

### Ask the agent
<!-- learn
id: diff-review-ask-agent
title: Ask the agent about a diff line
text: Select lines in Branch review and press ⇧⌘A to quote them into the session's chat beside the diff.
area: development
level: next
kind: feature
since: next
action: nav:projects
-->

The session's chat opens beside the diff (toolbar button or ⌥⌘C). Select lines, then choose **Ask agent** in the context menu or press ⇧⌘A: the lines are quoted into the chat's draft, which you finish and send.

### Go to definition
<!-- learn
id: diff-review-go-to-definition
title: Jump to a definition from the diff
text: ⌘-click a name in the diff, or press ⌃⌘J, to open its definition without leaving the review.
area: development
level: power
kind: tip
since: next
action: nav:projects
-->

⌘-click a name in the diff's new side, or press ⌃⌘J, to jump to its definition. ⇧⌘U shows all usages in a strip under the diff. A file the branch did not change opens in a read-only preview with **← Back to diff**.

### What the agent sends back

The agent can leave notes, shown in the diff and under **The agent's walkthrough**, and answer your comments; a reply shows as **Agent:** under the comment. Comments it fixed move to **Resolved by the agent**; **Reopen** puts one back for the next round.

### Undo a hunk
<!-- learn
id: diff-review-undo-hunk
title: Undo one hunk of the agent's change
text: Press **Undo** on a hunk in Branch review to revert those lines; the agent is told not to redo them.
area: development
level: power
kind: feature
since: 0.24.0
action: nav:projects
-->

**Undo** on a hunk in the diff reverts those lines in the folder at once, with no confirmation, and lists them under **Undone**. The agent is told and does not redo them without asking. Undo is off once the round is sent and while the agent works, and for binary, symlinked and very large files.

### Next rounds

After a verdict, the toolbar offers **Start next round** (the same as **Refresh**). The view switch then offers **All changes** and **Since round N**. Unresolved comments carry to the new round and follow their quoted lines when the code moves. A comment whose lines are gone stays, marked outdated. A file keeps its **Viewed** mark while its content and mode are unchanged.

## Using it

1. Press **Review** on the session's strip, or choose **Review Branch** in a session's row menu.
2. Click a file. Read the diff. **Inline** switches to one column.
3. To comment, select lines, right-click and choose **Comment**, type your note and press **Add**. Comments on the removed side are allowed in the **All changes** view.
4. Tick **Viewed** on files you have read. ⌥⌘↑ and ⌥⌘↓ jump to the previous and next unviewed file.
5. **Request changes (n)**, or **Approve** when there is nothing to fix. A banner tells you what happened to the line: "Line pasted — press Return in the terminal", "Will be sent when the agent's turn ends", or "Copied — paste it into the terminal".

A draft has **Delete**. A carried comment has **Edit** and **Resolve**; resolved comments are not carried again.

## When it's empty or wrong

- **"Nothing to review" / "Nothing new since round N".** No change since the base or that round. Make or wait for edits, then **Refresh**.
- **"On main — only uncommitted edits are reviewed".** Nothing is committed past main, so only uncommitted edits are in the round.
- **The Review button is not there.** It shows on a session's strip only with uncommitted edits, unpushed commits or a feature branch; otherwise use **Review Branch** in the row menu.
- **"Round N's snapshot is gone — showing all changes".** Git pruned it. You lose only the **Since round** view.
- **"The diff is too large; later files show without hunks".** Open those files in the [code viewer](code-viewer.md).
- **"Undo is off while the agent is working".** Wait until the session stops, then **Undo**.
- **"This round was already sent".** Press **Refresh** to open the next round.
- **Git LFS files show a pointer or raw bytes.** Filters are switched off while reading.

## Related

- [Sessions](sessions.md) and [Asks](asks.md): a review ask is another way to ask for your eyes.
- [Workbench](README.md)

For developers: [docs/features/diff-reviewer.md](../../../features/diff-reviewer.md)
