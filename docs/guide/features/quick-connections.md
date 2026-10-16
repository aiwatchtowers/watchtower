# Quick Connections

Quick Connections let the [AI Chat](ai-chat.md) read from a tool Watchtower does not sync, such as a tracker or a notes app, by plugging in that tool's MCP server. They are for tools you want to ask about now and then, not to watch in the background.

## Why use it

Slack, Gmail, Calendar and Jira are synced and searchable. For anything else, you would otherwise copy and paste. Add the tool as a Quick Connection and ask "what's on my Trello board for this sprint?" in the chat; the assistant calls the tool live. Nothing is synced or stored beyond the connection itself.

## How it works

**Read-only by design.** A connection is never handed to the assistant whole. When you enable it, Watchtower lists the server's tools once and allows only those the server marks read-only. If the server does not say, a tool is allowed when its name starts with get, list, search, read, find, describe or lookup and does not go on to create, update, delete, send or the like. Every other tool stays hidden. Tools the server declares as writes can never be allowed.

**Where it works.** Only chats that can use tools see a connection: the main AI Chat and a target's chat. Draft-only chats never do. Automations can call the same allowed tools through their `mcp()` function. Quick Connections work only with the Claude AI provider; under Codex or Ollama the Settings card says so, and enabled connections do nothing.

**Secrets.** An API key or header never goes in the database or on a command line. It lives in a private file on your Mac, readable only by you. For servers that offer sign-in, OAuth is used instead and Watchtower refreshes the token before each chat.

**Plain http is refused.** Headers (and OAuth tokens) are sent only over https. Plain http is accepted only for a server on your own Mac (`localhost`, `127.0.0.1`). For a server on your network, use https or an SSH tunnel to localhost.

## Using it

1. Open **Settings → Connections → Quick Connections** and click **Add Connection**.
2. Enter a **Name**. Choose **Kind**: **stdio (local process)** runs a command on your Mac (a **Command** and optional arguments, for example `npx -y trello-mcp`); **http (remote server)** takes a **Server URL**.
3. For http, choose **Sign in with OAuth (recommended)**, which opens the server's authorization page after **Add**, or **Headers (manual)** to enter a static key.
4. Click **Add**. The connection starts off. Turn on its **Enabled** switch; this lists its tools.
5. Open **Tools** under the connection to see each tool labelled **read-only**, **unmarked** (the server does not say whether it writes) or **write**. Switch read-only and unmarked tools on or off. **Refresh list** re-reads them from the server; **Use defaults** returns to the read-only default.
6. To remove a connection, click **Remove**. The assistant loses its tools at once and the stored secret is deleted.

Only add stdio commands you trust: a local process has the same access to your Mac as anything you run yourself.

## When it's empty or wrong

The status dot shows the state: green is OK, orange is a problem the next chat retries (hover for the reason), red means the sign-in was revoked.

- **Orange, no usable tools.** The server's tools could not be listed, or none is read-only. The connection is not offered to the chat. Fix the server, then toggle **Enabled** or press **Refresh list**.
- **Red, with Sign in again.** The server revoked the grant. Click **Sign in again**.
- **A tool you need is missing.** It is marked as a write, or it was added to the server after the last listing. Press **Refresh list**; a declared write stays off.
- **The assistant ignores the connection.** Check the provider: Quick Connections need Claude.

## Related

- [AI Chat](ai-chat.md)
- [Automations](automations.md)

For developers: docs/features/quick-connections.md
