# Code viewer

The code viewer lets you read and edit the files of a workbench folder without leaving Watchtower, and jump around them by name, symbol or text. You use it to check what the agent wrote, fix a line, or find where something is defined.

## Why use it

When an agent finishes, the first questions are "what did it touch?" and "where is this used?". The viewer answers them next to the terminal, in the same window, with the folder's git marks on every file.

## How it works

The **FILES** section at the bottom of the sessions panel lists the folder. A file opens in the **Files** pane in an editor with tabs. A single click opens a preview tab that the next click replaces; a double click, or your first edit, keeps it. Folders such as `.git` and `node_modules` are not listed.

Files carry git marks (modified, added, untracked, deleted, conflicted). When the session you look at works in a git worktree, the viewer follows it to that worktree, with its own tabs. See [Worktrees and cleanup](worktrees-and-cleanup.md).

Edits save themselves about a second after you stop typing, and at once when you switch tab. Watchtower never saves over a version it has not seen. If the file changed on disk meanwhile, a banner offers **Reload from disk** or to keep your edit. A file deleted under your edits is only written back when you choose to.

### Previewing HTML files

An `.html` or `.htm` file, such as a slide deck an agent wrote, has a **Source** | **Preview** switch above it. **Preview** renders the file as it is on disk, and reloads it each time the file changes (your edit saves itself in about a second, or the agent writes it again). Its CSS, scripts, fonts and images load from the file's own folder, without hidden files such as `.env`, or over https from jsDelivr, cdnjs, unpkg or Google Fonts (so a reveal.js deck works). Nothing else reaches the internet, and its links open nothing. When the file names resources anywhere else, a line under the switch says so: **Blocked 2 external resources: example.com, …**. The page shows without them; Watchtower never fetches them for it. Click it and use the arrow keys to page through a deck.

The buttons next to the switch are **Reload** (while previewing), **Present** (full screen, Esc leaves) and **Open in Browser**. The browser gets the file from a private address on your Mac (`http://127.0.0.1:…`) that serves only that file's folder, without hidden files, until you quit Watchtower. There the page runs sandboxed: it can load scripts, styles, fonts and images from the folder and from the same four CDNs, nothing from other sites, but its script cannot read the folder's other files, keeps no cookies, and opens no pop-ups. It can still go to another website, as any page you open can. Video files do not play from this address.

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

- **"No definition of …"** The language is indexed and has no such name, or the index is still building ("Still indexing…"). Use **Show All Usages** or the **Text** scope.
- **"Language X: text search".** There is no grammar for that language, so definitions come from a text search.
- **"Git status unavailable — the marks may be out of date."** Git failed to answer. The last marks stay.
- **A banner says the file changed.** Another program wrote it. Choose **Reload from disk**, or keep your version.
- **Navigate items are grey.** The workbench window is not in front.
- **"Files in a hidden folder are not opened in the browser."** The file sits in a folder whose name starts with a dot, inside the workbench (for example `.config`). Move it, or use **Preview**. Files over 100 MB are not served either.
- **The HTML preview misses images or styles.** They live outside the file's folder (for example `../assets`) or in a hidden folder, come over plain `http://` or from a site other than jsDelivr, cdnjs, unpkg or Google Fonts (the **Blocked … external resources** line names it), or are fetched by a script rather than linked. Move them next to the file, or load them from one of those CDNs with a `<script>`, `<link>` or `<img>` tag.

## Related

- [Sessions](sessions.md) and [Diff review](diff-review.md): what the agent changed.
- [Workbench](README.md)

For developers: [docs/features/code-navigation.md](../../../features/code-navigation.md)
