# Watchtower: User Roles and Usage Scenarios

> Watchtower is a local AI assistant for work communications. It syncs Slack and Google Calendar into a local database, and analyzes communications and schedule using AI (Claude / Codex). All data is stored locally, no API keys required.

---

## 1. Engineering Manager / Team Lead

**Core value:** seeing the big picture — what the team is working on, where the bottlenecks are, who needs help — without reading hundreds of Slack messages.

### Daily scenarios

| Scenario | Watchtower feature | How it works |
|---|---|---|
| Morning review | **Daily Briefing** | A personalized digest: what needs attention, tasks for the day, team events, people dynamics, communication recommendations |
| What happened overnight | **Catchup** | A quick AI recap of activity since the last visit |
| Who's waiting on my reply | **Inbox** | Auto-detection of @mentions and DMs, AI prioritization (urgent/pending), automatic closing after a reply |
| My tasks for the day | **Tasks** | A "Today" section: overdue + due today + high priority. Statuses, delegation, ball-on |
| Meeting prep | **Meeting Prep** | AI generates talking points, open questions, and notes on each participant based on people cards and tracks |

### Strategic scenarios

| Scenario | Feature | How it works |
|---|---|---|
| Team health | **People Cards + Team Summary** | AI profiles of each person: communication style, role in decisions, red flags, achievements. An overall team summary |
| Team dynamics | **Team Pulse** (in Briefing) | Spikes/drops in activity, conflicts, collaborations, blockers |
| Initiative tracking | **Tracks** | Automatically generated narratives: what's happening, who's the driver/blocker, current status |
| Decisions made | **Decisions** | A flat list of decisions from all channels with importance level and author |
| Weekly trends | **Weekly Trends** | Hot topics, key decisions, open questions for the week |
| Communication coaching | **People Cards** → coaching | Recommendations: how to best interact with a specific person, given their style |

### Role-specific setup
- **Profile**: role = Manager, set reports/peers/manager → the briefing and people cards adapt accordingly
- **Watch List**: priority channels and people → boosted priority in analysis
- **Channel Statistics**: recommendations on what to mute (70%+ bots), what to favorite

---

## 2. Individual Contributor (IC) / Developer

**Core value:** not drowning in the Slack stream — knowing what's personally important, quickly finding decisions and context.

### Daily scenarios

| Scenario | Feature | How it works |
|---|---|---|
| What I missed | **Catchup** | An AI summary since the last visit or for a specified period (2h, 24h) |
| Who mentioned me | **Inbox** | @mentions and DMs with priorities. Snooze, dismiss, create a task from an inbox item |
| My tasks | **Tasks** | A personal to-do list: created from tracks/digests/inbox, checklists, deadlines |
| Question about a project | **AI Chat** | Ask "Who made the decision on the API in #backend?" — AI searches the local database |
| Message search | **Search** | Full-text search across all synced messages |

### Work scenarios

| Scenario | Feature | How it works |
|---|---|---|
| Context before code review | **Channel Digests** | A channel summary: topics, decisions, action items. What was discussed and what was concluded |
| Prepping for a 1:1 | **Meeting Prep** + **People Cards** | Talking points on open questions with the manager + coaching tips |
| Status of my initiative | **Tracks** | Auto-tracking of cross-channel discussions. Timeline, participants, current status |
| Schedule for the day | **Calendar** | Google Calendar integration: today's/tomorrow's events, next event in the sidebar |
| Feedback to AI | **Feedback** | Thumbs up/down on digests, tracks, decisions → AI improves over time |

### Role-specific setup
- **Profile**: role = IC → the briefing focuses on technical tasks and blockers
- **Watch List**: your project's channels with high priority
- **Mute**: channels with 70%+ bots → saves tokens and keeps the briefing clean

---

## 3. Product Manager / Product Owner

**Core value:** keeping a finger on the pulse of development — which decisions were made, where the bottleneck is, what's being discussed — without diving into technical details.

### Key scenarios

| Scenario | Feature | How it works |
|---|---|---|
| Initiative status | **Tracks** | Narrative tracks with current status, participants (driver/reviewer/blocker), priority |
| Decisions made | **Decisions** | All decisions from technical channels, sorted by importance |
| Morning review | **Daily Briefing** | Attention items, what happened, team pulse — all in one place |
| Standup prep | **Catchup** + **Tracks** | What changed over the last day on tracked topics |
| Planning prep | **Weekly Trends** | Weekly trends: hot topics, open questions, key decisions |
| AI questions | **Chat** | "What's the status of the migration to the new API?" — AI answers based on Slack data |

### Setup
- **Watch List**: product channels + key developers
- **Profile**: role = Direction Owner → the briefing focuses on strategic decisions and cross-team coordination
- **Calendar**: sync for meeting prep before planning sessions

---

## 4. Tech Lead / Staff Engineer

**Core value:** seeing the technical picture across channels — where architectural decisions are made, who's blocking what, which discussions need attention.

### Key scenarios

| Scenario | Feature | How it works |
|---|---|---|
| Cross-team decisions | **Tracks** | Automatically groups discussions from different channels into a single narrative |
| Architectural decisions | **Decisions** filtered by channel | What was decided in #architecture, #backend, #infra |
| Who's blocking | **People Cards** → red_flags + **Tracks** → blockers | AI identifies blockers and red flags from communication patterns |
| Team overview | **Team Summary** | Overall dynamics: collaborations, conflicts, bottlenecks |
| Design review prep | **Meeting Prep** | Context on participants, open questions, related tracks |
| Trends | **Weekly Trends** | Strategic patterns for the week |

### Setup
- **Watch List**: all technical channels + key people with high priority
- **Digest model**: a more powerful model (Opus/GPT-5.4) can be selected for better analysis quality

---

## 5. Director / Head of Direction

**Core value:** a strategic overview without needing to read Slack — trends, team health, key decisions.

### Key scenarios

| Scenario | Feature | How it works |
|---|---|---|
| Weekly review | **Weekly Trends** | Hot topics, strategic decisions, cross-team patterns |
| Team health | **Team Summary** + **People Cards** | Overall dynamics, red flags, achievements, conflicts |
| Key decisions | **Decisions** | Filtered by importance: critical/high only |
| Strategic initiatives | **Tracks** | High-priority tracks across teams |
| Morning review | **Daily Briefing** | Personalized for Direction Owner: strategy and cross-team coordination |
| Meeting prep | **Meeting Prep** | Context on each participant + open questions |

### Setup
- **Profile**: role = Direction Owner
- **Watch List**: strategic channels, heads of direction
- **Briefing hour**: set to a convenient time (default 8:00)

---

## 6. New Team Member / Onboarding

**Core value:** quickly getting up to speed — who does what, which decisions have been made, what the team's communication style is.

### Key scenarios

| Scenario | Feature | How it works |
|---|---|---|
| Channel context | **Channel Digests** | Accumulated summaries: topics, decisions, key discussions |
| Who's who | **People Cards** | Colleague profiles: communication style, role, what they work on |
| Decision history | **Decisions** | Why things were done a certain way — decisions with context |
| Current initiatives | **Tracks** | What's currently in progress, who's responsible for what |
| Project questions | **AI Chat** | Ask anything about the history of Slack discussions |
| Discussion search | **Search** | Find a specific message or topic |

### Setup
- **Full sync**: the first sync can use `--full` for deep history
- **Watch List**: your team's channels
- **Profile**: set manager/peers for relevant people cards

---

## Feature-to-role matrix

| Feature | Manager | IC | PM/PO | Tech Lead | Director | New Member |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| **Daily Briefing** | +++ | ++ | +++ | ++ | +++ | + |
| **Inbox** | +++ | +++ | + | ++ | + | ++ |
| **Tasks** | +++ | +++ | ++ | ++ | + | + |
| **Tracks** | +++ | ++ | +++ | +++ | +++ | ++ |
| **Channel Digests** | ++ | +++ | ++ | +++ | + | +++ |
| **People Cards** | +++ | + | + | ++ | +++ | +++ |
| **Team Summary** | +++ | - | ++ | +++ | +++ | + |
| **Decisions** | ++ | ++ | +++ | +++ | +++ | +++ |
| **Weekly Trends** | ++ | + | +++ | +++ | +++ | + |
| **Meeting Prep** | +++ | ++ | +++ | +++ | +++ | ++ |
| **Calendar** | +++ | ++ | +++ | ++ | +++ | + |
| **AI Chat** | ++ | +++ | +++ | +++ | + | +++ |
| **Search** | + | +++ | ++ | ++ | - | +++ |
| **Catchup** | ++ | +++ | +++ | ++ | + | ++ |
| **Feedback** | ++ | ++ | + | ++ | + | + |
| **Channel Stats** | ++ | + | + | ++ | + | ++ |

`+++` = primary feature for the role, `++` = useful, `+` = occasionally used, `-` = rarely used

---

## Shared capabilities (all roles)

### AI providers
- **Claude** (Anthropic): Sonnet, Haiku, Opus — the default
- **Codex** (OpenAI): GPT-5.4, GPT-5.4 Mini — an alternative
- Switch with one click (Settings or the `--provider` flag)

### Privacy and security
- All data is stored **locally** in SQLite
- AI runs via a CLI subprocess — no API keys in the config
- Read-only access to Slack (cannot send messages)
- No cloud sync

### Interfaces
- **Desktop App** (macOS): a full GUI with sidebar navigation, badges, real-time updates
- **CLI**: all features available via `watchtower <command>` commands
- **Daemon**: background sync every 15 minutes (configurable)

### AI self-learning
- **Feedback** (thumbs up/down) on digests, tracks, decisions, briefings
- **Prompt Tuning**: AI analyzes feedback and suggests prompt improvements
- **Running Context**: AI remembers channel context between analysis cycles (up to 7 days)

---

## Quick start by role

### Manager
```bash
watchtower auth login          # Connect Slack
watchtower calendar login      # Connect Google Calendar
watchtower profile             # Set role to Manager, reports, peers
watchtower watch add #team-channel --priority high
watchtower daemon start        # Start background sync
# Open the Desktop App → Daily Briefing every morning
```

### IC / Developer
```bash
watchtower auth login
watchtower profile             # Set role to IC, manager, peers
watchtower watch add #my-project --priority high
watchtower daemon start
# Use: Inbox → Tasks → Catchup → Chat
```

### PM / Product Owner
```bash
watchtower auth login
watchtower calendar login
watchtower profile             # Set role to Direction Owner
watchtower watch add #product --priority high
watchtower watch add #engineering
watchtower daemon start
# Focus: Tracks → Decisions → Weekly Trends → Briefing
```
