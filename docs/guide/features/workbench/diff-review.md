# Diff review

Diff review lets you read what an agent session changed, comment on lines, and send your comments back to the agent as one round. You use it when a session says it is done and you want to check the code, not the story.

## Why use it

A pull request review needs a pull request. Here you review before anything is committed, and the agent reads your comments by itself. The next round shows only what changed since, and keeps your Viewed marks for files that did not move.

## How it works

**Review Changes** in a session's row menu opens the **Changes** pane and starts a round. Watchtower snapshots the folder's working tree (tracked and untracked files, not ignored ones) and compares it with a base, the point where the branch left the default branch. The snapshot only writes git objects. It touches no branch, no index and no file.

The pane has a file list, a diff, and a list of comments. Files show added, modified, deleted or renamed, their line counts and a **Viewed** checkbox. Lockfiles, generated files and very large files are folded by name. Binary and oversized files show a placeholder.

A round moves through three states: you collect drafts, **Send review** stores the round, and the agent reads it with its `get_review` tool, which marks it delivered. Watchtower then puts one line into the session, `Review round #N sent (n comments) — read it with get_review N using the watchtower-workbench skill.`. The agent sees your comment text, the quoted lines and where each sits.

### Next rounds

After a send, **Refresh** opens the next round. The view switch then offers **All** and **Since round N**. Comments not yet resolved are carried to the new round and follow their quoted lines when the code moved. A comment whose lines are gone stays, marked outdated. A file keeps its **Viewed** mark while its content and mode are unchanged.

## Using it

1. Row menu, **Review Changes**.
2. Click a file. Read the diff. **Inline** switches to one column.
3. To comment, select lines, right-click and choose **Comment**, type your note and press **Add**. Comments on the removed side are allowed in the **All** view.
4. Tick **Viewed** on files you have read.
5. **Send review (n)**. A banner tells you what happened to the line: "Line pasted — press Return in the terminal", "Will be sent when the agent's turn ends", or "Copied — paste it into the terminal".

A draft has **Delete**. A carried comment has **Edit** and **Resolve**, and an outdated one has **Resolve**. Resolved comments are not carried again.

## When it's empty or wrong

- **"No changes yet".** The folder matches the base. Make or wait for edits, then **Refresh**.
- **The changes button is off.** There is no session to review. Use the row menu of a session.
- **"Round N's snapshot is gone — showing all changes".** Git pruned the old snapshot. You lose only the **Since round** view.
- **"The diff is too large; later files show without hunks".** The diff hit its size limit. Open those files in the [code viewer](code-viewer.md).
- **"This round was already sent".** Press **Refresh** to open the next round.
- **Files tracked by Git LFS show a pointer or raw bytes.** Filters are switched off while reading.

## Related

- [Sessions](sessions.md) and [Asks](asks.md): a review ask is another way to ask for your eyes.
- [Workbench](README.md)

For developers: [docs/features/diff-reviewer.md](../../../features/diff-reviewer.md)
