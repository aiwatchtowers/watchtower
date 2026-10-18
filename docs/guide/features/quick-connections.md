# Quick Connections

Quick Connections let the [AI Chat](ai-chat.md) read from a tool Watchtower does not sync, such as a tracker or a notes app, by plugging in that tool's MCP server. They are for tools you want to ask about now and then, not to watch in the background.

## Why use it

Slack, Gmail, Calendar and Jira are synced and searchable. For anything else, you would otherwise copy and paste. Add the tool as a Quick Connection.

Then ask "what's on my Trello board for this sprint?" in the chat; the assistant calls the tool live. Nothing is synced or stored beyond the connection itself.

## How it works

**Read-only by design.** A connection is never handed to the assistant whole. When you enable it, Watchtower lists the server's tools once and allows only those the server marks read-only.

If the server does not say, a tool is allowed when its name starts with get, list, search, read, find, describe or lookup and does not go on to create, update, delete, send or the like. Every other tool stays hidden, and tools the server declares as writes can never be allowed.

**Where it works.** Only chats that can use tools see a connection: the main AI Chat and a target's chat. Draft-only chats never do. Automations can call the same allowed tools through their `mcp()` function. Quick Connections work with the Claude and Codex AI providers; under Ollama the Settings card says so, and enabled connections do nothing.

**The server's text is not an instruction.** A connection's tool descriptions, its own instructions and the answers its tools return come from outside Watchtower. The assistant is told to treat them as data from that server, never to follow orders found in them, and to send the server only what your question needs.

**Secrets.** An API key or header never goes in the database or on a command line. It lives in a private file on your Mac, readable only by you. For servers that offer sign-in, OAuth is used instead and Watchtower refreshes the token before each chat.

**Your own codex and Claude Code servers.** The chat never loads the MCP servers you set up for codex (`~/.codex/config.toml`) or Claude Code (`~/.claude.json`); your codex sign-in and model settings still apply. Import those servers to use them here: they then follow the same read-only rules. Under Codex, when your codex config has MCP servers, the Quick Connections card reminds you once.

**Plain http is refused.** Headers (and OAuth tokens) are sent only over https. Plain http is accepted only for a server on your own Mac (`localhost`, `127.0.0.1`). For a server on your network, use https or an SSH tunnel to localhost.

## Using it

1. Open **Settings → Connections → Quick Connections** and click **Add Connection**.
2. Enter a **Name**. Choose **Kind**: **stdio (local process)** runs a command on your Mac (a **Command** and optional arguments, for example `npx -y trello-mcp`); **http (remote server)** takes a **Server URL**.
3. For http, choose **Sign in with OAuth (recommended)**, which opens the server's authorization page after **Add**, or **Headers (manual)** to enter a static key.
4. Click **Add**. The connection starts off. Turn on its **Enabled** switch; this lists its tools.
5. Open **Tools** under the connection to see each tool labelled **read-only**, **unmarked** (the server does not say whether it writes) or **write**. Switch read-only and unmarked tools on or off. **Refresh list** re-reads them from the server; **Use defaults** returns to the read-only default.
6. To bring in servers you already use with codex or Claude Code, click **Import from codex and Claude Code…**. Every server that can be imported starts ticked, except one turned off in its config; untick any you don't want and click **Import**. Each one is enabled at once (one turned off in its config comes in off) and its keys move to the private secret file. A remote server that needs a sign-in opens its authorization page; **Cancel** stops it.
7. To remove a connection, click **Remove**. The assistant loses its tools at once and the stored secret is deleted.

Only add stdio commands you trust: a local process has the same access to your Mac as anything you run yourself.

## When it's empty or wrong

The status dot shows the state: green is OK, orange is a problem the next chat retries (hover for the reason), red means the sign-in was revoked.

- **Orange, no usable tools.** The server's tools could not be listed, or none is read-only. The connection is not offered to the chat. Fix the server, then toggle **Enabled** or press **Refresh list**.
- **Red, with Sign in again.** The server revoked the grant. Click **Sign in again**.
- **A tool you need is missing.** It is marked as a write, or it was added to the server after the last listing. Press **Refresh list**; a declared write stays off.
- **The assistant ignores the connection.** Check the provider: Quick Connections need Claude or Codex.
- **A server from codex or Claude Code is missing from the chat.** The chat does not read those configs. Use **Import from codex and Claude Code…**.
- **Import says "Can't import".** The reason follows: an SSE server, a server that runs in a set working folder, a variable such as `$API_TOKEN` that neither the app nor your login shell sets, a `${…}` variable in a command or URL, or a key sent over plain http. Add that server with **Add Connection** instead.
- **A connection says "not available in the codex chat".** One of its environment variables (a proxy, certificate, path or codex setting, for example) would change how codex itself runs. Rename the variable on the server side, or use the Claude provider for it.
- **Add says the name is reserved.** `watchtower` and any name starting with `watchtower_` belong to Watchtower's own tools. Pick another name. A connection added under such a name earlier shows orange and is not offered to the chat: remove it and add it again under another name.
- **An imported server has a different name.** Names hold only letters, digits, `-` and `_`, and two servers cannot share one; the list says what was renamed.

## Related

- [AI Chat](ai-chat.md)
- [Automations](automations.md)

For developers: [docs/features/quick-connections.md](../../features/quick-connections.md)
