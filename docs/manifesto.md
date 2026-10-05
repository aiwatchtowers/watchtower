# The Watchtower Manifesto

## The tools we have

We work inside a pile of tools: a messenger, a tracker, a wiki, mail, a calendar, meeting notes, a code host, an issue board. Each one is good at its own job. Together they were never designed. They do not share a model of who is involved, what was decided, why, and what happens next. We learned to stitch them together in our heads, and we got good at it.

And then there are meetings, online and in the room, where much of the real deciding happens. They are not a tool at all, and what is said there usually evaporates or ends up as a few lines in someone's notes.

The tools were built for people clicking through interfaces. That was the right design for the world they were born in.

## Why that stops working now

The world has changed. Real work no longer sits in one tool. It lives in the gaps between them: a thread turns into a ticket, the ticket points to a page, the page gets argued over in a meeting, and the meeting ends in a pull request. An agent that is supposed to help needs all of that as one connected picture. Today it gets scattered stores behind narrow APIs.

Vendors answer by bolting an assistant onto their own product. Each of these assistants sees only its own slice. It does not matter how strong the model is if the context it reasons over is cut into pieces. AI search over many tools helps you find things, but finding is not working. Raw connectors give an agent access, but access is not understanding. Every session starts from zero, and nothing is remembered.

So the fragmentation we once absorbed with our own attention now drags down both us and our agents.

## We are not replacing them

Throwing the old tools out is not an option. There is no real alternative to them, our teams live in them, and a great deal is built on top of them. Asking anyone to migrate is a losing proposition.

So we keep them, and we change their role. They stay where conversations, tickets and documents live and travel. Watchtower reads from them continuously and writes back to them when you say so. The old tools become infrastructure. The work itself moves into a new experience on top.

## What we build instead

One place where you and your agents work from the same context.

- **One connected picture.** Messages, tickets, pages, mail, calendar, meeting transcripts and code are synced and indexed locally, then linked into people, decisions, tracks and history. This is a standing model of your work, not a query fired at an API at the moment you ask.
- **Shared ground with your agents.** An agent sees what you see: the tasks, the people, the decisions, the memory of what happened before. You stop re-explaining the world at the start of every session.
- **Acting, not just answering.** Replies, page edits and ticket updates go out from the same place, and you approve them before they leave.

## Where the multiplier comes from

The gain is not a smarter chatbot. It comes from removing the work that sits between the actual work:

1. **Context assembly.** "What did we discuss about X, who owns it, what changed?" stops being half an hour of searching across six tabs. For you and for your agent, the answer is already assembled.
2. **No re-briefing.** An agent that starts with your context, your tasks and your memory gets to useful output in minutes, not after a long prompt you have to rewrite every time.
3. **Attention on what matters.** Instead of badges in every tool, one surface tells you what needs you: a direct question, a blocked decision, a meeting to prepare for, or a recap of what you missed while you were away.
4. **Delegation that holds.** Agents get the task together with its context, come back with a clear question when they are stuck, and hand back finished work. You review and decide. You stop babysitting them. (For code, the Workbench takes this furthest: a coding agent works a folder alongside you, tracks its tasks and reports where things stand.)
5. **Closing the loop.** Decisions turn into tickets, replies and page edits without copying anything between windows.

Each of these saves minutes. Together they change how much one person, working with their agents, can carry.

## A platform, not a silo

Watchtower does not keep its picture to itself. The same context it assembles for you is exposed through its own MCP server and command line, so a coding agent in your terminal, a script or a more specialized tool can build on it instead of rebuilding it.

It also grows by connection, not by roadmap. Connect an external MCP server and its data is within reach of Watchtower and your agents right away. Deeper native integrations go further: they sync continuously and feed the connected picture.

## Principles

- **Build on top, never replace.** Existing tools stay the systems of record.
- **Local first.** Your data is synced to and stored on your machine, not in our cloud. The model you choose receives the context a task needs, not your whole archive.
- **The human decides.** Agents propose, and nothing leaves on your behalf without your approval.
- **Agents are colleagues, not features.** They get the same context, the same tasks and the same memory you have.
- **Personal first, team next.** We start with one person and their agents, because that is where the gain is immediate and the trust is easiest to earn. The same model of shared context and shared work is how teams will follow.
