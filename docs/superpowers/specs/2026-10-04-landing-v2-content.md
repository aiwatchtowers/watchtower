# Landing v2 — content spec

**Date:** 2026-10-04
**Type:** Functional content spec (sections + messaging, not visual design). Replaces `2026-06-27-landing-page-design.md`.
**Source of truth for the message:** `docs/manifesto.md`.
**Approach (owner, 2026-10-04):** evolve the current aiwatchtowers.com, not a redesign. Every section was reviewed one by one with the owner; the visual language, layout and motion stay, the content changes. Prototyping and design come first; code starts only once the whole site is approved.
**Where it ships:** the private `aiwatchtowers/lending` repo (`public/index.html`, Cloudflare; a push to its `main` deploys production). This spec lands here; the page change is a PR there.

## Why the current page has to change

- **Wrong product.** "Your AI chief of staff for Slack": a morning brief over four sources. Agents, the Workbench, the chat with tools, Confluence, meetings and the MCP surface are missing.
- **False claims.** "Read-only access… nothing is sent, modified, or deleted" is no longer true: Slack send, Confluence edits and Jira issue creation write back, each after approval. "Never sent to a third-party server" ignores that the owner's chosen LLM provider receives task context. "No Cloud" overpromises for the same reason.
- **Retired features in the carousel.** The Inbox (replaced by attention detection) and Targets in the old sense.

## Positioning

- **Audience:** one person and their AI agents (personal first). Teams appear as the next step, not as the pitch.
- **Hero promise:** one workspace where you and your agents work from the same context.
- **Competitors:** compared by class only (vendor-built assistants, AI search, raw connectors), never by name.
- **Threaded through every section:** keep your tools · shared context · you decide · local first.

## Home page, section by section

Each section notes the owner decision (asks #49–#56, 2026-10-04) and what stays from the current page.

### 1. Hero (ask #49)
- **Stays:** the screenshot that expands to full screen on scroll.
- **H1:** "One workspace for you and your agents."
- **Subhead:** Watchtower connects Slack, Jira, Confluence, mail, calendar, meetings and code into one picture on your Mac, so you and your AI agents work from the same context.
- **CTAs:** Download for macOS · Read the manifesto.
- **Kicker:** "Local-first · For you and your agents".
- **Screenshot:** the real Workbench board of the Watchtower project itself (owner decision 2026-10-05: an invented chat or Today screen looks like every other product). Tasks and sessions translated to English, rendered 2× from an exact replica of the app screen; the local path becomes `~/code/watchtower` and the live-database counters leave the status bar. On narrow screens the image keeps a 760px width and is cropped on the right.

### 2. The problem (asks #50, #51)
- **H2:** "Your tools were built for people clicking. Your agents need context."
- **Three cards:**
  - **Scattered context.** Work lives between the tools: a thread becomes a ticket, a page, a meeting, a pull request. No tool holds the whole picture.
  - **Assistants that see one slice.** Every vendor added AI to its own product. Each one sees only its own data.
  - **Agents that start from zero.** Raw connectors give access, not understanding. Every session you re-explain the world.
- **Line under the cards:** meetings, online and in the room, are where much of the deciding happens, and none of it is captured.
- **Heading over the band (ask #68):** "And none of it connects."
- **Band visual:** the tools as islands (Chat, Tracker, Wiki, Mail, Calendar, Meetings, Code) whose dashed lines break off before reaching each other or an agent. The radar is no longer here: it pictured the solution under a problem caption.

### 3. The idea (new section; ask #51)
- **H2:** "Keep your tools. Change their role."
- **Body:** replacing them is not an option. Watchtower keeps them as the systems of record, reads from them continuously, writes back when you approve, and moves the work into one experience on top.
- **Visual:** the current animated radar, moved here: every tool's dashed line flows into it, and beams go out to "you" and "your agents".
- **Link:** "Why we build it this way →" to the manifesto.

### 4. How it works (asks #52, #53)
- **Stays:** H2 "Up and running in three steps", the three-step layout, the animated counters, the green "Setup complete" card and "You're ready."
1. **Connect.** Slack, Jira, Confluence, Gmail, Google Calendar, your meetings, your code folders. No migration, nothing changes for your team.
2. **Watchtower builds the picture.** Synced and indexed on your Mac, linked into people, decisions, tracks and memory.
3. **You and your agents work from it.** Animated card with two lanes: "You: 3 need you · 1 meeting prep ready" and "Agents: 2 questions · 1 PR ready".
- **Privacy card:** title "Local by default. You decide what goes out." Three points:
  - Your data is stored in a local database on your Mac. We run no servers that hold it.
  - You choose the model (your Claude or Codex subscription, or a local one through Ollama). It receives only the context a task needs.
  - Anything that writes to your accounts is proposed first and runs only after you approve it.
- **Google paragraph stays verbatim.** It is part of the OAuth verification (Homepage requirements). Gmail and Calendar stay read-only.
- **Badges:** Local · Your model · Approve to send · No telemetry. (Checked: the code ships no analytics or crash-reporting SDK; "telemetry" in the code means local auth-status rows.)

### 5. Where the multiplier comes from (ask #54)
- **Stays:** the sticky carousel (text left, progress bars, mini-visuals right).
- **H2 (ask #68):** "Less work between the work." The kicker stays "Where the multiplier comes from".
- **Five slides**, one per mechanism, each with a product mini-visual:

| Mechanism | Mini-visual |
|---|---|
| Context assembly | An answer with source chips from Slack, Jira, Confluence and a meeting |
| No re-briefing | An agent calling Watchtower's MCP server and getting people, tracks and memory back |
| Attention on what matters | Catch-Up: waiting on you · on fire · decided |
| Delegation that holds | The Workbench: an agent's question in "Waiting for you" |
| Closing the loop | A proposed Slack reply with Approve / Edit |

- **Right after:** a compact grid of the four categories, each linking to its page: Work communication · Tasks & Jira · Meetings · Development in Workbench (titles and pitches as in onboarding). Heading (ask #68): "Start with what you need".

### 6. Built different, on purpose (ask #55)
- **Stays:** the card layout with mini-visuals.
- **Intro:** "Built for people who already live in Slack, Jira, Confluence and their calendar: no migration, no retraining, no lock-in."
- **Six cards:** NO MIGRATION (more tool chips) · NO LOCK-IN (Claude / Codex / Ollama) · YOU DECIDE (an Approve card) · AGENTS ARE COLLEAGUES (one context for you and your agent) · NATIVE · PROACTIVE. PRIVATE is dropped: the privacy card covers it.
- **Accordion copy (ask #68):** YOU DECIDE — "Agents propose. You approve." / "Nothing leaves on your behalf without your approval. A Slack reply, a page edit or a new Jira issue waits for you, and you can edit it first." AGENTS ARE COLLEAGUES — "One context for you and your agents." / "Your agents get the same people, decisions, tasks and memory you see, so you stop re-explaining the world at the start of every session."

### 7. Open source (ask #56)
- **Stays:** everything.
- **Adds one line:** the MCP server and CLI are open, so you can build your own tools on Watchtower's context.

### 8. Built with Watchtower (ask #56)
- **Replaces** the "first teams" placeholder.
- **Message:** Watchtower is built with Watchtower. Claude Code works the project's own Workbench board, with 300+ tasks closed so far. Use the live count at publish time.

### 9. Final CTA (ask #56)
- **Stays:** the animated scene, the kicker "From the watchtower", H2 "See the whole picture.", the Download button.
- **New subhead:** "You and your agents, one context, and every tool you already use kept in place."

## New pages (to review next)

- **Manifesto** (`/manifesto/`, approved in ask #69): `docs/manifesto.md` verbatim as a long-read page. Hero kicker "The Watchtower Manifesto", H1 "Keep your tools. Change their role.", subhead "Why the tools we work in stop being enough once agents join the work, and what we build on top of them instead." Sticky contents on the left (hidden on narrow screens), sections numbered 01–07, the "One place…" line as a pull quote, the five mechanisms as numbered cards, the principles as a card grid, closing CTA with Download and Source on GitHub.
- **Four category pages**, matching the onboarding goals: Work communication · Tasks & Jira · Meetings · Development in Workbench.
- **Integrations**: what Watchtower connects to today, by group, with how each one works (native sync, on your Mac, MCP on demand) and what it may do (read, write with approval).
- Desktop and mobile versions of each, in the current visual language.
- **Visuals (asks #73, #74):** no app screenshots outside the home hero, because the product changes too fast for them to stay true. The home hero keeps the one board screenshot (cheap to re-render). Category pages are illustrated with icons and text only.
- **Category page template (ask #70):** hero (the onboarding pitch as H1) → "What it does" (four icon cards) → "You and your agents" (two lanes) → what it needs / connects to → links to the other categories and a CTA. Development in Workbench is drafted first.

## Also changes
- `<title>`, meta description and OG text follow the hero.
- Nav gains Manifesto and Integrations.

## Out of scope
- The `/guide/` pages (still describe the Inbox, Tasks and others). A separate pass.

## Final decisions (2026-10-05)
- All pages approved (asks #75–#77, #82). URLs: `/`, `/manifesto/`, `/work-communication/`, `/tasks-and-jira/`, `/meetings/`, `/development/`, `/integrations/`.
- Workbench copy is agent-neutral ("your coding agent"). Claude Code is named only where it is a fact today: the Development page's requirements and the Integrations card. Codex in the Workbench is a later product change, not a site claim.
- Meetings says that an unplanned meeting (a call nobody scheduled, a talk in the room) is recorded and transcribed too, and that a recording survives the app quitting.
- Integrations groups the connections by kind and states for each how it connects (native sync, on your Mac, on demand) and what it reads and may write after approval.
- The site keeps its CSP: self-hosted fonts and images, one external script file (`/assets/site.js`) for the nav menu and the home accordion. New OG image and sitemap entries.
