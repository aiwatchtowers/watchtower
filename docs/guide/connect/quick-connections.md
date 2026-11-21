# Connect a Quick Connection with the assistant

Press **Connect with Claude** (or Codex) in **Connections → Quick Connections** and the assistant adds another tool's MCP server as a Quick Connection: it fills the name and the command or URL, and you type any key into a secure card it never sees. Turning the connection on is yours: a confirm card in the panel. This page is the assistant's script: **Agent** steps are its own, **You** steps are yours, **You only** steps are the customer's alone.

## What you get

- The tool's read-only MCP tools in the chat and in automations; a tool the server marks as a write stays off ([Quick Connections](../features/quick-connections.md)).
- Keys kept in a private file on your Mac, never in the database or on a command line.

## Before you start

- You know the tool's MCP server: a command to run on your Mac (like `npx -y trello-mcp`) or an `https://` URL. Its own docs say which; plain http works only for a server on your own Mac.
- Add only commands you trust: a local process has the same access to your Mac as anything you run yourself.
- Your organization's policy allows this server. With an allow list set, a server outside it is never added or turned on.
- The assistant reads only modelcontextprotocol.io. It leaves any other page and stops, and it never opens a page that shows the tool's key.

## Steps

1. **Agent:** Call `connect_status`. If a flow is running, wait for it with `connect_wait` or ask the customer whether to `connect_cancel` it. Ask the customer which tool to add and for its server's command or URL from the tool's docs, and whether it needs a key or a sign-in.
2. **Agent:** Call `set_fields` with `name` (letters, digits, `-` and `_`; not `watchtower`), `kind` (`stdio` or `http`), and `command` with `args` for stdio or `url` for http. For an http server that offers sign-in, add `oauth` set to `true`. For a key, add `header` (http, like `Authorization`) or `variable` (stdio, like `API_KEY`): the name the key goes under, never the key.
3. **Agent:** Without a key, call `connect_start`. With a key, call `request_secret` with kind `mcp_secret` instead, and tell the customer where the tool's docs say to make the key; do not open that page yourself.
4. **You only:** If you were asked for a key, make it on the tool's site, copy it into the card, leave that page, then press **Send**.
5. **You:** For a server with sign-in, sign in on the page that opens in your browser and approve.
6. **Check:** Call `connect_wait` (or read the result of `request_secret`); while it says `waiting`, call it again. On `connected`, go on; on `failed` or `timeout`, tell the customer the reason and stop at [If something goes wrong](#if-something-goes-wrong).
7. **Agent:** The connection is added but off. Call `connect_start` with `enable` set to its name. The panel shows a confirm card: turning it on lets the chat call its read-only tools.
8. **You:** Read the card and press its confirm button, or decline. A decline keeps the connection off.
9. **Check:** Call `connect_wait` and then `connect_status`. Tell the customer how many read-only tools the server offers, and that **Tools** under the connection switches them.

## If something goes wrong

The assistant's panel always offers **Set up by hand**, which opens **Connections → Quick Connections**.

- **Your organization does not allow this server** (`policy`). It is outside the allow list your organization set. Ask your IT team.
- **"Another operation is already in progress."** (`busy`). Another Quick Connections change is running. Wait for it, then start again.
- **The name is reserved.** `watchtower` and names starting with `watchtower_` belong to Watchtower's own tools. Pick another name and run it again.
- **"Arguments contain a quote that is never closed."** Fix the arguments and run it again.
- **"Added but could not find the new connection to sign in."** Open the connection in **Connections → Quick Connections** and sign in there.
- **"Sign in failed" or "Enable failed" with a message.** The assistant reads you the message. Check the command or URL and try again.
- **The status dot is orange: no usable tools.** The server's tools could not be listed, or none is read-only, so the chat does not get it. Fix the server, then toggle **Enabled** or press **Refresh list**.
- **The confirm card was declined, the card was cancelled, or the wait ran out** (`timeout`). The connection stays off. Start again when you are ready.

```connect
service: quickConnections
domains: modelcontextprotocol.io
tools: connect_status, connect_start, connect_wait, connect_cancel, set_fields, request_secret
secrets: mcp_secret
options: enable
```
