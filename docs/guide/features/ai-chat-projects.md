# Chat projects

A project groups chats that share context: instructions given in every chat, files, and pinned sources (Jira projects, Slack channels, Confluence spaces, targets, tracks, people). Pinned channels, projects and spaces rank first in the project's knowledge search.

## How it works
<!-- learn
id: chat-projects
title: Group chats in a project
text: Open the project menu in **Chats** and pick **New Project…** to give a set of chats shared instructions and files.
area: assistant
level: power
kind: feature
since: 0.24.0
action: nav:chat
-->

Open the menu in the **Chats** panel header (**All chats ⌄**) and pick **New Project…**, or pick a project to open its page. Inside a project the panel lists only its chats, with **Project overview** as the first row.

The page has:

- **The name**, editable in place, and a **⋯** menu with **Rename** and **Delete Project…**. Deleting a project deletes its files and keeps its chats; they move out of the project.
- **A message box** to start a chat in the project.
- **Chats in this project · N**, a click opens one.
- **Instructions**: a preview and **Edit**. They go to the assistant in every chat of the project.
- **Knowledge**: files and pinned sources in one list. **+ Add** offers **Files…** and **Source…**; you can also drop files on it.

An edit reaches every chat in the project on its next message.

## When it's empty or wrong

- **A project edit seems ignored.** A reply being written finishes first; the change applies from the next message.
- **A chat is missing from the project.** Right-click it in **All chats** and use **Move to Project**.

## Related

- [Chats](ai-chat.md)
