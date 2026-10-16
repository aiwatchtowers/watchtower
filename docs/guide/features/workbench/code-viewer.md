# Code viewer

The code viewer lets you read and edit the files of a workbench folder without leaving Watchtower, and jump around them by name, symbol or text. You use it to check what the agent wrote, fix a line, or find where something is defined.

## Why use it

When an agent finishes, the first questions are "what did it touch?" and "where is this used?". The viewer answers them next to the terminal, in the same window, with the folder's git marks on every file.

## How it works

The **FILES** section at the bottom of the sessions panel lists the folder. A file opens in the **Files** pane in an editor with tabs. A single click opens a preview tab that the next click replaces; a double click, or your first edit, keeps it. Folders such as `.git` and `node_modules` are not listed.

Files carry git marks (modified, added, untracked, deleted, conflicted). When the session you look at works in a git worktree, the viewer follows it to that worktree, with its own tabs. See [Worktrees and cleanup](worktrees-and-cleanup.md).

Edits save themselves about a second after you stop typing, and at once when you switch tab. Watchtower never saves over a version it has not seen. If the file changed on disk meanwhile, a banner offers **Reload from disk** or to keep your edit. A file deleted under your edits is only written back when you choose to.

### Finding things

Watchtower indexes the folder's definitions in memory, rebuilt from the folder each time. It indexes the files git lists, or all but hidden folders outside a repository, and skips binary files and files over 2 MB. A language without a grammar falls back to a text search.

| What | How |
|---|---|
| Search files, symbols and text | **Open Quickly…** (⇧⌘O, or press ⇧ twice). The scope switch has **All**, **Files**, **Symbols** and **Text**. |
| Search text only | **Find in Workbench…** (⇧⌘F) |
| Go to a definition | **Go to Definition** (⌃⌘J, or ⌘-click). With several candidates a menu lists them and ends in **Show All Usages…**. |
| See every use of a name | **Show All Usages** (⇧⌘U) opens the Usages tab of the inspector. |
| Jump within a file | **File Symbols…** (⌃6) |
| Go back and forward | **Back** and **Forward** (⌃⌘← and ⌃⌘→). |

The **Navigate** menu holds all of these. It is enabled only while a workbench window is in front.

### Asking about code

Select code and press ⌘I (**Ask AI**), or press ⌘↩ in Open Quickly. A small popover answers about the selection, or the cursor line, using the code around it and the index. If the answer suggests a change, **Apply** puts it in the editor as one undo step. The **Questions** tab of the inspector lists past questions.

The assistant reads the folder with read-only tools to answer. A model that cannot read files, such as a local Ollama model, answers only from the code around your question. To continue in an agent session, use **Hand to Session** (⌥⌘↩): it pastes the conversation into a running session or a new one.

## Using it

1. Open a file from **FILES**. Edit it, or just read.
2. Press ⇧⌘O and type part of a name. Arrow to a result and press Return.
3. ⌘-click a name to jump to its definition. Press ⌃⌘← to return.
4. In the terminal, ⌘-click a `path:line` to open it in the viewer.

The **+** in **FILES** and each row's menu create files and folders, rename, copy the path and **Move to Trash**.

## When it's empty or wrong

- **"No definition of …"** The language is indexed and has no such name, or the index is still building ("still indexing"). Use **Show All Usages** or the **Text** scope.
- **"Language X: text search".** There is no grammar for that language, so definitions come from a text search.
- **"Git status unavailable — the marks may be out of date."** Git failed to answer. The last marks stay.
- **A banner says the file changed.** Another program wrote it. Choose **Reload from disk**, or keep your version.
- **Navigate items are grey.** The workbench window is not in front.

## Related

- [Sessions](sessions.md) and [Diff review](diff-review.md): what the agent changed.
- [Workbench](README.md)

For developers: [docs/features/code-navigation.md](../../../features/code-navigation.md)
