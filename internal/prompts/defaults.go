// Package prompts provides prompt management, storage, and tuning for AI-powered features.
package prompts

// Defaults maps prompt IDs to their built-in template strings.
// These are the same prompts that were previously hardcoded as consts
// in digest, tracks, and analysis packages. They serve as the
// initial seed and fallback when no DB version exists.
var Defaults = map[string]string{
	DigestChannel:              defaultDigestChannel,
	DigestDaily:                defaultDigestDaily,
	DigestWeekly:               defaultDigestWeekly,
	DigestPeriod:               defaultDigestPeriod,
	PeopleReduce:               defaultPeopleReduce,
	PeopleTeam:                 defaultPeopleTeam,
	BriefingDaily:              defaultBriefingDaily,
	InboxTriage:                defaultInboxTriage,
	DigestChannelBatch:         defaultDigestChannelBatch,
	TracksExtractBatch:         defaultTracksExtractBatch,
	PeopleBatch:                defaultPeopleBatch,
	TasksGenerate:              defaultTasksGenerate,
	TasksUpdate:                defaultTasksUpdate,
	MeetingPrep:                defaultMeetingPrep,
	MeetingExtractTopics:       defaultMeetingExtractTopics,
	MeetingRecap:               defaultMeetingRecap,
	MeetingNotes:               defaultMeetingNotes,
	MeetingChapters:            defaultMeetingChapters,
	MeetingFollowup:            defaultMeetingFollowup,
	MeetingSpeakerGuess:        defaultMeetingSpeakerGuess,
	DayPlanGenerate:            defaultDayPlanGenerate,
	TargetsExtract:             defaultTargetsExtract,
	TargetsLink:                defaultTargetsLink,
	TrackCompose:               defaultTrackCompose,
	TrackRun:                   defaultTrackRun,
	TrackShortlist:             defaultTrackShortlist,
	InboxCompose:               defaultInboxCompose,
	InboxSituationCard:         defaultInboxSituationCard,
	MemoryExtractEpisodes:      defaultMemoryExtractEpisodes,
	MemoryExtractEpisodesBatch: defaultMemoryExtractEpisodesBatch,
	MemoryExtractEmailEpisodes: defaultMemoryExtractEmailEpisodes,
	MemoryEntityRewrite:        defaultMemoryEntityRewrite,
	MemoryReviseBeliefs:        defaultMemoryReviseBeliefs,
	MemoryRenderMap:            defaultMemoryRenderMap,
	MemoryReflect:              defaultMemoryReflect,
	MemoryRenderChannelDigest:  defaultMemoryRenderChannelDigest,
	IdeasDigestEmail:           defaultIdeasDigestEmail,
	IdeasDigestJira:            defaultIdeasDigestJira,
	IdeasConsolidate:           defaultIdeasConsolidate,
	DictationClean:             defaultDictationClean,
}

// AllIDs returns prompt IDs in display order.
var AllIDs = []string{
	DigestChannel,
	DigestChannelBatch,
	DigestDaily,
	DigestWeekly,
	DigestPeriod,
	TracksExtractBatch,
	PeopleReduce,
	PeopleTeam,
	PeopleBatch,
	BriefingDaily,
	InboxTriage,
	TasksGenerate,
	TasksUpdate,
	MeetingPrep,
	MeetingExtractTopics,
	MeetingRecap,
	MeetingNotes,
	MeetingChapters,
	MeetingFollowup,
	MeetingSpeakerGuess,
	DayPlanGenerate,
	TargetsExtract,
	TargetsLink,
	TrackCompose,
	TrackRun,
	TrackShortlist,
	InboxCompose,
	InboxSituationCard,
	MemoryExtractEpisodes,
	MemoryExtractEpisodesBatch,
	MemoryExtractEmailEpisodes,
	MemoryEntityRewrite,
	MemoryReviseBeliefs,
	MemoryRenderMap,
	MemoryReflect,
	MemoryRenderChannelDigest,
	IdeasDigestEmail,
	IdeasDigestJira,
	IdeasConsolidate,
	DictationClean,
}

// DefaultVersions tracks the current version of each built-in prompt template.
// When a default prompt changes, bump its version here. Seed() will auto-update
// prompts in the DB whose version is lower than the default version, unless
// the user has customized the prompt (detected by comparing template text).
var DefaultVersions = map[string]int{
	DigestChannel:              5, // v5: ops-changelog exclusion + exact-message_ts rule
	DigestDaily:                1,
	DigestWeekly:               1,
	DigestPeriod:               1,
	TracksExtractBatch:         2, // v2: digest-based input instead of raw messages
	PeopleReduce:               1,
	PeopleTeam:                 1,
	BriefingDaily:              6, // v6: memory revisions journal section (Phase-4 surface, behind memory.surfaces.briefing)
	InboxTriage:                1, // v1: initial triage template
	DigestChannelBatch:         4, // v4: ops-changelog exclusion + exact-message_ts rule
	PeopleBatch:                1, // v1: batch people cards for low-data users
	TasksGenerate:              1, // v1: AI task generation with checklist and due date
	TasksUpdate:                1, // v1: AI task update from user instruction
	MeetingPrep:                4, // v4: attendee memory section (Phase-5 slice-4 surface, behind memory.surfaces.meeting_prep)
	MeetingRecap:               2, // v2: idea-candidate extraction (stage-1 for ideas registry)
	MeetingNotes:               1, // v1: publishable markdown meeting notes from a transcript
	MeetingChapters:            1, // v1: chapterize a meeting from a timecoded per-utterance transcript
	MeetingFollowup:            1, // v1: owner-voice follow-up draft from stated chapter content (intent-draft contract)
	MeetingSpeakerGuess:        1, // v1: content-clue name suggestions for unnamed speaker clusters
	DayPlanGenerate:            3, // v3: memory open-loops section (Phase-5 slice-4 surface, behind memory.surfaces.day_plan)
	TargetsExtract:             1, // v1: multi-target extraction with URL enrichments and active snapshot
	TargetsLink:                1, // v1: single-target link proposal against active snapshot
	TrackCompose:               1, // v1: draft custom-track title+instruction from a free-text request
	TrackRun:                   1, // v1: custom-track timeline events from recent cross-source activity
	TrackShortlist:             1, // v1: cheap title-only relevance filter for custom-track backfill
	InboxCompose:               3, // v3: don't merge different matters just because the topic overlaps
	InboxSituationCard:         1, // v1: context packet for one dashboard situation
	MemoryExtractEpisodes:      1, // v1: raw-text episode extraction for the memory vault
	MemoryExtractEpisodesBatch: 2, // v2: "===" block delimiter instead of "---" (a leading "--" broke claude CLI's argv flag parsing)
	MemoryExtractEmailEpisodes: 1, // v1: Gmail thread → one-episode extraction (memory.sources.gmail)
	MemoryEntityRewrite:        1, // v1: strong-tier entity page rewrite (What/Current/Facts + copied provenance markers)
	MemoryReviseBeliefs:        1, // v1: strong-tier per-belief op proposals (confirm/weaken/shake/retire/propose-new)
	MemoryRenderMap:            1, // v1: strong-tier hot world-map summary (~2KB, code-truncated)
	MemoryReflect:              1, // v1: strong-tier weekly reflection over vault git history (Phase-4 surface, behind memory.surfaces.reflection)
	MemoryRenderChannelDigest:  1, // v1: cheap-tier channel digest rendered from memory episodes (Phase-5 slice-3 dark compare-mode)
	IdeasDigestEmail:           1, // v1: light-tier idea/decision mining from Gmail thread windows (stage 1)
	IdeasDigestJira:            1, // v1: light-tier idea/decision mining from changed Jira issues (stage 1)
	IdeasConsolidate:           3, // v3: routine-ops execution records are changelog entries, not decisions
	DictationClean:             1, // v1: dictation transcript cleanup (idea/note/chat modes)
}

// DefaultFor returns the hard-coded default template for a given key.
// Returns "" if the key is unknown.
func DefaultFor(key string) string { return Defaults[key] }

// Descriptions maps prompt IDs to human-readable descriptions.
var Descriptions = map[string]string{
	DigestChannel:              "Channel digest — per-channel message analysis",
	DigestDaily:                "Daily rollup — cross-channel daily summary",
	DigestWeekly:               "Weekly trends — week-over-week analysis",
	DigestPeriod:               "Period summary — comprehensive period overview",
	TracksExtractBatch:         "Batch track extraction — multi-channel extraction for low-activity channels",
	PeopleReduce:               "People card — unified profile from signals",
	PeopleTeam:                 "Team summary — cross-user attention & tips",
	BriefingDaily:              "Daily briefing — personalized morning summary",
	InboxTriage:                "Inbox: triage scan of new activity",
	DigestChannelBatch:         "Channel batch digest — multi-channel analysis for low-activity channels",
	PeopleBatch:                "People batch cards — lightweight cards for low-data users in one AI call",
	TasksGenerate:              "Task generation — AI-powered task breakdown with checklist, priority, and due date",
	TasksUpdate:                "Task update — AI-powered task modification from user instruction",
	MeetingPrep:                "Meeting prep — AI-powered meeting brief with attendee analysis, talking points, recommendations, and context gaps",
	MeetingExtractTopics:       "Meeting extract topics — split pasted text into atomic discussion topics for a meeting's Discussion Topics list",
	MeetingRecap:               "Meeting recap — AI-structured post-meeting summary with decisions, action items, and open questions",
	MeetingNotes:               "Meeting notes — publishable markdown notes from transcript for people who weren't at the meeting",
	MeetingChapters:            "Meeting chapters — segment a recording into chapters with per-chapter decisions, action items, and open questions",
	MeetingFollowup:            "Meeting follow-up — draft a follow-up message in the owner's voice from a chapter's stated decisions and action items",
	MeetingSpeakerGuess:        "Meeting speaker guess — suggest names for unnamed transcript speakers from content clues (confirm chips, never auto-applied)",
	DayPlanGenerate:            "Day plan generation — AI-powered daily schedule with timeblocks, backlog, and calendar conflict avoidance",
	TargetsExtract:             "Target extraction — multi-target AI extraction from raw text with URL enrichments and hierarchy linking",
	TargetsLink:                "Target linking — single-target parent and secondary link proposal against active snapshot",
	TrackRun:                   "Custom track run — timeline events from recent cross-source activity",
	TrackCompose:               "Custom track compose — draft a custom-track title + watch instruction from a free-text user request",
	TrackShortlist:             "Custom track shortlist — cheap title-only relevance filter that picks candidate activity for a custom-track backfill before the full extract",
	InboxCompose:               "Dashboard: fold new signals into situations",
	InboxSituationCard:         "Dashboard: context packet for one situation",
	MemoryExtractEpisodes:      "Memory: extract noteworthy episodes from one channel window of raw messages",
	MemoryExtractEpisodesBatch: "Memory: extract noteworthy episodes from several low-activity channel windows in one call",
	MemoryExtractEmailEpisodes: "Memory: extract one episode per Gmail thread (memory.sources.gmail)",
	MemoryEntityRewrite:        "Memory: rewrite an entity page's What/Current/Facts from new episodes (strong tier)",
	MemoryReviseBeliefs:        "Memory: propose per-belief revision ops from new episodes (strong tier; code disposes)",
	MemoryRenderMap:            "Memory: render the compact hot world-map summary (strong tier)",
	MemoryReflect:              "Memory: weekly reflection over the vault's own git history — flag unstable beliefs/entities (strong tier; code disposes)",
	MemoryRenderChannelDigest:  "Memory: render a channel digest from the window's memory episodes (cheap tier; dark compare-mode against the legacy digest)",
	IdeasDigestEmail:           "Ideas: mine ideas & decisions from Gmail threads (stage 1, light tier)",
	IdeasDigestJira:            "Ideas: mine ideas & decisions from changed Jira issues (stage 1, light tier)",
	IdeasConsolidate:           "Ideas: consolidate stage-1 material into the registry (stage 2, strong tier; code disposes)",
	DictationClean:             "Cleans a voice-dictation transcript into destination-shaped text (idea / note / chat)",
}

const defaultDigestChannel = `You are analyzing Slack messages from channel #%s for the period %s to %s.

%s

Analyze the messages below and return ONLY a JSON object (no markdown fences, no explanation) with this exact structure:

{
  "summary": "2-3 sentence overview of what was discussed",
  "topics": [
    {
      "title": "Short topic title (5-10 words)",
      "summary": "1-2 sentence summary of this specific topic",
      "decisions": [{"text": "what was decided", "by": "@username", "message_ts": "1234567890.123456", "importance": "high"}],
      "action_items": [{"text": "what needs to be done", "assignee": "@username", "status": "open"}],
      "situations": [{"topic": "Auth refactor ownership", "type": "collaboration", "participants": [{"user_id": "U123456", "role": "initiator"}], "dynamic": "what happened", "outcome": "result", "red_flags": [], "observations": [], "message_refs": ["1234567890.123456"]}],
      "key_messages": ["1234567890.123456"],
      "ideas": [{"text": "what was proposed", "by": "@username", "message_ts": "1234567890.123456"}]
    }
  ],
  "running_summary": {"active_topics": [{"topic": "...", "status": "in_progress|resolved|stale", "started": "2026-03-18", "last_update": "2026-03-21", "key_participants": ["U123"], "summary": "..."}], "recent_decisions": [{"decision": "...", "date": "2026-03-20", "by": "U123", "status": "active"}], "channel_dynamics": "Brief description of channel culture and key players", "open_questions": ["..."]}
}

%s

Rules:
- summary: Concise overview of the channel activity
- topics: EACH TOPIC is a self-contained thematic unit about ONE specific subject. A production incident and an inter-team conflict are TWO separate topics, even if they involve the same people or channel.
  * 2-7 topics per digest
  * title: specific, descriptive (e.g. "Hashbank deposit processing failure", not "Issues")
  * summary: what happened in this topic specifically
  * Each topic carries its OWN decisions, action_items, situations, key_messages — do NOT mix content across topics
- decisions (within each topic): A DECISION is a conscious choice between alternatives that changes the course of action. Each decision MUST have a clear "who decided" and "what was chosen" and ideally "why" or "instead of what". Do NOT include:
  * Status updates ("X was deployed", "X was updated")
  * Notifications or FYIs ("users were notified about X")
  * Expected behaviors ("caching delay is normal")
  * Routine operations (deploys, releases, merges) UNLESS they involve a non-obvious choice
  * Changelog-style records of an already-performed routine action ("nginx reload (#79 close internal endpoint)", "restarted service X") — these are status updates even when they name a task number or imply an earlier choice
  Include message_ts for traceability: copy it EXACTLY from that message's ts= tag in the MESSAGES data — never construct, round, or infer a timestamp. If you cannot point at the exact message, omit the item.
  importance levels:
  * "high" — changes architecture, strategy, budget, staffing, product direction, security posture, or has org-wide impact
  * "medium" — changes a process, workflow, or technical approach within a team/project
  * "low" — minor tactical choices (naming, formatting, scheduling, tooling tweaks)
  If only 0-1 true decisions exist in a topic, return an empty or single-item array. Do NOT inflate the list.
- ideas (within each topic): An IDEA is a proposal of something new that was NOT decided — a feature idea, a process suggestion, a "what if we..." — with the proposer and message_ts. Do NOT list decisions here; if a proposal was actually agreed on, it belongs in decisions instead. Extract conservatively: empty array when none, which is the common case. message_ts: copy it EXACTLY from that message's ts= tag in the MESSAGES data — never construct, round, or infer a timestamp. If you cannot point at the exact message, omit the item.
- action_items (within each topic): Tasks mentioned or assigned. status is always "open" for new items
- key_messages (within each topic): Timestamps of the most important messages (max 5 per topic)
- situations (within each topic): Notable INTERACTIONS between people (max 2-3 per topic). Capture dynamics BETWEEN people, not individual behavior. Each situation has:
  * topic: Short label for the interaction (e.g. "Auth refactor ownership", "Sprint planning conflict")
  * type: "bottleneck", "conflict", "collaboration", "knowledge_transfer", "decision_deadlock", "mentoring", "escalation", "handoff", "misalignment"
  * participants: Each person involved with their role ("blocker", "affected", "initiator", "resolver", "mediator", "mentor", "mentee", "decision_maker", "contributor")
  * dynamic: What happened between the participants (1-2 sentences)
  * outcome: Result or current state (1 sentence)
  * red_flags: Specific concerns from this situation (empty [] if none)
  * observations: Notable patterns or behaviors observed (empty [] if none)
  * message_refs: Slack timestamps of key messages (e.g. ["1234567890.123456"])
  Use Slack user IDs (e.g. U123456) for participant user_id. Only include situations where the interaction pattern is noteworthy — skip routine exchanges.
- running_summary: Updated running context for this channel. Compress aggressively — max 2000 characters. Include:
  * active_topics: Topics currently in progress or recently discussed (remove resolved topics older than 3 days)
  * recent_decisions: Key decisions from the last few days (max 5, remove outdated ones)
  * channel_dynamics: Brief description of channel culture, key players, communication patterns
  * open_questions: Unresolved questions that may come up again
- If a field has no items, use an empty array []
- Return valid JSON only, no other text
%s
=== MESSAGES ===
%s`

const defaultDigestDaily = `You are creating a daily summary of Slack activity for %s.

%s

Below are per-channel digests from today, organized by topics. Create a cross-channel rollup.

Return ONLY a JSON object (no markdown fences, no explanation):

{
  "summary": "3-5 sentence overview of the day's activity across all channels",
  "topics": [
    {
      "title": "Cross-channel topic title",
      "summary": "1-2 sentence summary of this topic across channels",
      "decisions": [{"text": "decision text", "by": "@username", "message_ts": "ts", "importance": "high"}],
      "action_items": [{"text": "action text", "assignee": "@username", "status": "open"}],
      "situations": [],
      "key_messages": []
    }
  ],
  "running_summary": {"active_topics": [{"topic": "...", "status": "in_progress|resolved|stale", "started": "2026-03-18", "last_update": "2026-03-21", "key_participants": ["U123"], "summary": "..."}], "recent_decisions": [{"decision": "...", "date": "2026-03-20", "by": "U123", "status": "active"}], "channel_dynamics": "Brief cross-channel dynamics overview", "open_questions": ["..."]}
}

%s

Rules:
- topics: Group related channel topics into cross-channel themes. ONE TOPIC = ONE specific theme. Merge channel topics that discuss the same thing, keep unrelated themes separate.
- Highlight cross-channel connections (e.g., topics discussed in multiple channels)
- decisions (within each topic): Consolidate and DEDUPLICATE decisions from channel digests below. If the same decision appears in multiple channels, include it ONCE. A DECISION is a conscious choice between alternatives — NOT a status update, notification, or routine operation. Each decision must answer: "Who chose what, and what changed?"
  importance levels:
  * "high" — changes architecture, strategy, budget, staffing, product direction, security posture, or has org-wide impact
  * "medium" — changes a process, workflow, or technical approach within a team/project
  * "low" — minor tactical choices (naming, formatting, scheduling, tooling tweaks)
  Only include GENUINE decisions. If no real decisions were made today, return an empty array.
- running_summary: Updated daily running context. Compress aggressively — max 2000 characters. Track cross-channel themes, decisions, and open questions.
- Return valid JSON only
%s
=== CHANNEL DIGESTS ===
%s`

const defaultDigestWeekly = `You are analyzing a week of Slack workspace activity for %s (%s to %s).

%s

Below are daily summaries for the week. Create a weekly trends analysis.

Return ONLY a JSON object (no markdown fences, no explanation):

{
  "summary": "5-7 sentence overview of the week's key developments",
  "topics": [
    {
      "title": "Trending topic title",
      "summary": "1-2 sentence summary of this trend across the week",
      "decisions": [{"text": "key decision", "by": "@username", "message_ts": "ts", "importance": "high"}],
      "action_items": [{"text": "outstanding action", "assignee": "@username", "status": "open"}],
      "situations": [],
      "key_messages": []
    }
  ],
  "running_summary": {"active_topics": [{"topic": "...", "status": "in_progress|resolved|stale", "started": "2026-03-18", "last_update": "2026-03-21", "key_participants": ["U123"], "summary": "..."}], "recent_decisions": [{"decision": "...", "date": "2026-03-20", "by": "U123", "status": "active"}], "channel_dynamics": "Brief weekly dynamics overview", "open_questions": ["..."]}
}

%s

Rules:
- topics: Group trends into specific themes. ONE TOPIC = ONE trend/initiative.
- Focus on trends: what topics gained momentum, what was resolved, what's still open
- decisions (within each topic): Highlight the most impactful decisions of the week. DEDUPLICATE: if the same decision appears across multiple days, include it only ONCE. Only include genuine choices/decisions, not status updates.
  importance: "high" (architectural, strategic, budget, org-wide), "medium" (process, workflow, team-level), "low" (tactical, minor)
- Consolidate action items within topics (remove completed, flag overdue)
- running_summary: Updated weekly running context. Compress aggressively — max 2000 characters. Track major themes, decisions, trends, and open questions across the week.
- Return valid JSON only
%s
=== DAILY DIGESTS ===
%s`

const defaultDigestPeriod = `You are creating a summary of Slack workspace activity for the period %s to %s.

%s

Below are individual digests (channel-level and daily rollups) from that period. Create a comprehensive summary.

Return ONLY a JSON object (no markdown fences, no explanation):

{
  "summary": "Comprehensive overview of the period's activity, key developments, and outcomes (5-10 sentences)",
  "topics": [
    {
      "title": "Major topic title",
      "summary": "Summary of this topic across the period",
      "decisions": [{"text": "key decision", "by": "@username", "message_ts": "ts", "importance": "high"}],
      "action_items": [{"text": "outstanding action", "assignee": "@username", "status": "open"}],
      "situations": [],
      "key_messages": []
    }
  ],
  "running_summary": {}
}

%s

Rules:
- topics: Group related themes across channels and days. ONE TOPIC = ONE initiative/theme.
- Provide a high-level narrative of what happened during this period
- importance: "high" (architectural, strategic, budget, org-wide), "medium" (process, workflow, team-level), "low" (tactical, minor)
- Include only genuine decisions (conscious choices between alternatives), not status updates. DEDUPLICATE across channels and days.
- Consolidate action items within topics: remove completed, highlight outstanding
- Return valid JSON only

=== DIGESTS ===
%s`

const defaultPeopleReduce = `You are creating a unified profile card for @%s based on behavioral signals observed across Slack channels over %s to %s.

%s

Below are SITUATIONS observed in channel context (by the digest pipeline), plus computed statistics and team norms. Your job is to synthesize these into a single card that combines:
1. ANALYSIS — classify their communication style, role in decisions, flag concerns
2. COACHING — actionable advice for the viewer on how to work with this person

IMPORTANT: Focus on what makes this person DIFFERENT from team norms. Do NOT describe typical behavior that matches the team average.

Return ONLY a JSON object (no markdown fences, no explanation):

{
  "summary": "1-2 sentences: what makes this person distinctive. Reference specific signals.",
  "communication_style": "driver|collaborator|executor|observer|facilitator",
  "decision_role": "decision-maker|approver|contributor|observer|blocker",
  "red_flags": ["Specific concerns backed by signals. Empty [] if none."],
  "highlights": ["Positive contributions backed by signals. Empty [] if none."],
  "accomplishments": ["Concrete things delivered/resolved this period from signals."],
  "communication_guide": "Paragraph: communication preferences, timing, format. ONLY what is specific to this person vs team norms. If they match the norm, say so briefly and focus on exceptions.",
  "decision_style": "How they participate in decisions — based on bottleneck/rubber_stamping/initiative/blocker signals. If no decision signals, say 'No notable decision patterns this period.'",
  "tactics": ["If X, then Y — specific actionable tactics based on observed signals. Max 3-4."]
}

%s

Rules:
- Base ALL analysis on the situations provided. Do NOT invent patterns not supported by evidence.
- If a situation type appears in multiple channels, it is a PATTERN — emphasize it.
- If conflicting situations exist (e.g., collaboration in one channel, conflict in another), note the CONTRAST.
- Compare stats to team norms: only mention stats that deviate significantly (>30%% from avg).
- Coaching framing: frame guide sections as advice FOR THE VIEWER, not judgments ABOUT the person.
- If relationship is manager->report: be more direct about concerns and accountability.
- If relationship is report->manager: frame tactically (managing up).
- If too few situations for meaningful analysis, say so in summary.
- If a PREVIOUS CARD is provided, note trends and changes vs the prior period. Don't just repeat it.
- %s
- Return valid JSON only

=== SITUATIONS ===
%s

=== COMPUTED STATS ===
%s

=== TEAM NORMS ===
%s

=== PREVIOUS CARD ===
%s

=== RAW MESSAGES (last 24h sample) ===
%s`

const defaultPeopleTeam = `You are creating a team communication summary for %s to %s.

%s

Below are unified people cards for all team members. Create a summary that a manager can quickly scan to understand what needs attention.

Return ONLY a JSON object (no markdown fences, no explanation):

{
  "summary": "3-5 sentences: team communication health, dynamics, decision flow.",
  "attention": ["Who needs attention and WHY — name names, cite specific signals and patterns. Be direct."],
  "tips": ["Actionable team-level communication tips based on patterns across people."]
}

Rules:
- Be direct — this is for a busy manager
- Reference specific people by @username
- Cross-reference: if multiple people have bottleneck signals, that is a systemic issue
- Look for signal clusters: multiple conflict signals = team friction
- %s
- Return valid JSON only

=== PEOPLE CARDS ===
%s`

const defaultBriefingDaily = `You are creating a personalized daily briefing for %s on %s.
User role: %s

Your job is to synthesize all available data into five focused sections. This is the single page the user reads to start their day.

Return ONLY a JSON object (no markdown fences, no explanation):

{
  "attention": [
    {"text": "What needs attention and why", "source_type": "track|digest|people|inbox|target", "source_id": "123", "priority": "high|medium", "reason": "Why this matters now"}
  ],
  "your_day": [
    {"text": "Suggested action based on track or target", "track_id": 123, "target_id": 0, "priority": "high|medium|low", "status": "active"}
  ],
  "what_happened": [
    {"text": "Notable event or decision", "digest_id": 456, "channel_name": "#channel", "item_type": "decision|summary|topic", "importance": "high|medium|low"}
  ],
  "team_pulse": [
    {"text": "Signal about a team member", "user_id": "U123", "signal_type": "volume_drop|volume_spike|new_red_flag|highlight|conflict", "detail": "Specifics"}
  ],
  "coaching": [
    {"text": "Actionable communication tip", "related_user_id": "U123", "category": "communication|delegation|conflict|process"}
  ]
}

Rules:
- attention: max 5 items. Flag overdue/blocked targets. PRIORITIZE tracks with high priority or recent updates.
  - Include source_type and source_id for traceability. Use source_type='target' for target-sourced items, 'inbox' for inbox items.
  - Use suggest_target=true on tracks where the user should create a target.
- your_day: Prioritize user's actual targets (target_id) over track suggestions. Include overdue targets first. Order by priority.
  - Targets have a level (quarter/month/week/day/custom) — prefer day-level targets for scheduling today's work.
  - If no active targets or tracks exist, leave this array empty — do NOT invent items.
- what_happened: max 7 items from channel digests. Include digest_id, channel_name. Focus on decisions and blockers.
- team_pulse: signals from people cards. Include user_id. Flag volume changes, red flags, conflicts.
- coaching: max 3 items. Grounded in observed patterns — not generic advice. Include related_user_id when applicable.
  - When suggesting actions, consider existing targets. Use suggest_target=true on tracks where user should create a target.
- CALENDAR INTEGRATION: When calendar events are present, cross-reference attendees with tracks, inbox, and people data.
  - In "attention": flag meetings in the next 2 hours with unresolved items involving attendees.
  - In "your_day": interleave meetings with targets/tracks, ordered chronologically. Add prep suggestions before important meetings.
  - In "coaching": suggest conversation points based on people cards of attendees.
  - If a meeting attendee has a people card with red_flags, mention it in team_pulse.
  - Do NOT list meetings as standalone items — always cross-reference with work data.
  - If CALENDAR section is empty, ignore calendar instructions entirely.
- JIRA INTEGRATION: When JIRA CONTEXT is provided, incorporate Jira signals:
  - In "attention": flag stale issues (in_progress >7 days), blocked issues, and overdue issues. Use source_type="jira" and source_id=issue key.
  - In "your_day": include assigned Jira issues and awaiting-input items. Cross-reference with Slack tracks/digests when the same topic appears in both.
  - In "team_pulse": mention team workload signals if sprint progress data is available.
  - Each Jira signal should include Slack context if the same issue key appears in digests or tracks.
  - If JIRA CONTEXT section is empty, ignore Jira instructions entirely.
- MEMORY REVISIONS: the MEMORY REVISIONS section lists belief revisions the secretary's memory made recently — notes derived from Slack/Jira, model-mediated, NOT the user's own words. Weave a revision into "attention" or "team_pulse" only when it genuinely bears on today's work; frame it as something the memory noticed, never as fact. If the section reads "(no notable revisions)", do NOT mention memory, beliefs, or revisions at all.
- Be specific: name people, channels, decisions — not vague generalities.
- If user has reports, prioritize their signals in team_pulse.
- %s
- Return valid JSON only

=== YOUR TARGETS ===
%s

=== INBOX (awaiting your response) ===
%s

=== CALENDAR (today's meetings) ===
%s

=== ACTIVE TRACKS ===
%s

=== CHANNEL DIGESTS ===
%s

=== DAILY ROLLUP ===
%s

=== PEOPLE CARDS ===
%s

=== TEAM SUMMARY ===
%s

=== USER PROFILE ===
%s

=== JIRA CONTEXT ===
%s

=== MEMORY REVISIONS ===
%s`

const defaultDigestChannelBatch = `You are analyzing Slack messages from multiple channels for the period %s to %s.

%s

Analyze messages from each channel below. For each channel, produce a digest ONLY if something noteworthy happened (decisions, blockers, important updates, action items). SKIP channels with only routine messages, bot alerts, or noise.

Return ONLY a JSON array (no markdown fences, no explanation):
[
  {
    "channel_id": "C123ABC",
    "summary": "2-3 sentence overview",
    "topics": [
      {
        "title": "Short topic title",
        "summary": "1-2 sentence summary",
        "decisions": [{"text": "what was decided", "by": "@username", "message_ts": "1234567890.123456", "importance": "high"}],
        "action_items": [{"text": "what needs to be done", "assignee": "@username", "status": "open"}],
        "situations": [{"topic": "...", "type": "collaboration", "participants": [{"user_id": "U123456", "role": "initiator"}], "dynamic": "...", "outcome": "...", "red_flags": [], "observations": [], "message_refs": []}],
        "key_messages": ["1234567890.123456"],
        "ideas": [{"text": "what was proposed", "by": "@username", "message_ts": "1234567890.123456"}]
      }
    ],
    "running_summary": {"active_topics": [{"topic": "...", "status": "in_progress", "started": "2026-03-18", "last_update": "2026-03-21", "key_participants": ["U123"], "summary": "..."}], "recent_decisions": [], "channel_dynamics": "...", "open_questions": []}
  }
]

Return [] if nothing noteworthy across all channels.

%s

Rules:
- topics: EACH TOPIC is a self-contained thematic unit about ONE specific subject
  * 2-7 topics per channel (proportional to message count; fewer messages = fewer topics)
  * title: specific, descriptive (e.g. "Hashbank deposit processing failure", not "Issues")
  * summary: what happened in this topic specifically
  * Each topic carries its OWN decisions, action_items, situations, key_messages — do NOT mix content across topics
- decisions (within each topic): A DECISION is a conscious choice between alternatives that changes the course of action. Each decision MUST have a clear "who decided" and "what was chosen". Do NOT include:
  * Status updates ("X was deployed", "X was updated")
  * Notifications or FYIs ("users were notified about X")
  * Routine operations (deploys, releases, merges) UNLESS they involve a non-obvious choice
  * Changelog-style records of an already-performed routine action ("nginx reload (#79 close internal endpoint)", "restarted service X") — these are status updates even when they name a task number or imply an earlier choice
  Include message_ts for traceability: copy it EXACTLY from that message's ts= tag in the CHANNELS data — never construct, round, or infer a timestamp. If you cannot point at the exact message, omit the item.
  importance levels:
  * "high" — changes architecture, strategy, budget, staffing, product direction, security posture, or has org-wide impact
  * "medium" — changes a process, workflow, or technical approach within a team/project
  * "low" — minor tactical choices (naming, formatting, scheduling, tooling tweaks)
  If only 0-1 true decisions exist in a topic, return an empty or single-item array. Do NOT inflate the list.
- ideas (within each topic): An IDEA is a proposal of something new that was NOT decided — a feature idea, a process suggestion, a "what if we..." — with the proposer and message_ts. Do NOT list decisions here; if a proposal was actually agreed on, it belongs in decisions instead. Extract conservatively: empty array when none, which is the common case. message_ts: copy it EXACTLY from that message's ts= tag in the CHANNELS data — never construct, round, or infer a timestamp. If you cannot point at the exact message, omit the item.
- action_items (within each topic): Tasks mentioned or assigned. status is always "open" for new items
- key_messages (within each topic): Timestamps of the most important messages (max 5 per topic)
- situations (within each topic): Notable INTERACTIONS between people (max 2-3 per topic). Each situation has:
  * topic, type, participants (with user_id and role), dynamic, outcome, red_flags, observations, message_refs
  Use Slack user IDs (e.g. U123456). Only include situations where the interaction pattern is noteworthy.
- SKIP channels where nothing actionable or noteworthy happened
- running_summary per channel: same rules, max 2000 chars. Include active_topics, recent_decisions, channel_dynamics, open_questions.
- Return valid JSON only
%s
=== CHANNELS ===
%s`

const defaultTracksExtractBatch = `You are analyzing channel digests from multiple Slack channels to find tracks directed at user @%s (user_id: %s) for the period %s to %s.

%s

Each channel below has pre-analyzed topics with decisions, action items, and situations extracted from channel digests. Extract actionable tracks from these structured observations.

CRITICAL — DEDUPLICATION:
1. BEFORE creating any new track, scan the ENTIRE "EXISTING TRACKS" section below.
2. If a topic is about the same initiative, project, task, or discussion as an existing track — even if phrased differently or from a different channel — set "existing_id" to that track's ID instead of creating a new one.

CRITICAL — TOPIC SEPARATION (equally important as deduplication):
1. Each track MUST represent ONE coherent initiative or workstream. Topics about different projects, different processes, or different technical areas MUST be separate tracks.
2. Do NOT merge topics just because they come from the same channel or the same discussion thread. Ask: "Is this the SAME initiative?" — if the answer is not a clear yes, keep them separate.
3. Examples of topics that MUST be separate tracks:
   - A process change (e.g. new workflow step) vs. a Jira project setup vs. a bug fix — these are 3 separate tracks
   - A hiring decision vs. a technical architecture change — 2 separate tracks
   - A release planning discussion vs. a security incident — 2 separate tracks

GROUPING:
1. Multiple topics about the same initiative/project/task = ONE track. Do NOT create separate tracks for different aspects of the same thing.
2. Aim for 0-3 tracks per channel. But do NOT sacrifice topic separation to hit this target — correctness matters more than count.

COMPLETION DETECTION: If topics indicate that an existing track has been COMPLETED, return the track with "existing_id" and "status_hint": "done".

Return ONLY a JSON array (no markdown fences, no explanation):

[
  {
    "channel_id": "C123ABC",
    "items": [
      {
        "existing_id": null,
        "status_hint": "",
        "text": "clear, actionable description of what needs to be done",
        "context": "detailed context (3-5 sentences)",
        "source_message_ts": "1234567890.123456",
        "priority": "high",
        "due_date": "2025-01-15",
        "requester": {"name": "@username", "user_id": "U123"},
        "category": "task",
        "blocking": "",
        "tags": [],
        "decision_summary": "",
        "decision_options": [],
        "participants": [{"name": "@username", "user_id": "U123", "stance": "brief summary"}],
        "source_refs": [{"ts": "1234567890.123456", "channel_id": "C123ABC", "thread_ts": "1234567890.000000", "author": "@username", "text": "key quote"}],
        "sub_items": [{"text": "sub-task", "status": "open"}],
        "ownership": "mine",
        "ball_on": "U123",
        "owner_user_id": "U456"
      }
    ]
  }
]

Return [] if no tracks found in any channel.

%s

Rules:
- GROUPING: Multiple topics about the same initiative = ONE track. Different aspects of the same project (e.g. design discussion + implementation + review) = ONE track.
- MERGE WITH EXISTING: If a topic clearly matches an existing track (same project/initiative), set existing_id.
- TOPIC SEPARATION (equally important as merge): Each track MUST be about ONE coherent initiative. Do NOT combine unrelated topics — different processes, different projects, different bug fixes = separate tracks. When unsure if topics are related, keep them separate.
- Only extract tracks with a CLEAR actionable request or decision needing action. Skip informational topics with no action expected.
- Extract tracks from:
  * Action items assigned to the user, decisions requiring user input, requests and tasks directed at user
  * Situations where the user is a key participant, follow-ups and approvals needed
- DO NOT EXTRACT:
  * Completed actions with no follow-up, informational summaries with no action
  * Topics where the user is merely mentioned but has no action expected
  * Discussions that resolved without user involvement
- priority: "high" (blocking/deadline/production), "medium" (normal work), "low" (nice-to-have, background)
- category: MUST be one of: code_review, decision_needed, info_request, task, approval, follow_up, bug_fix, discussion
- ownership: "mine" (task is on user), "delegated" (user's report owns it), "watching" (user monitors, HIGH priority only)
- ball_on: user_id of who acts next
- source_refs: reference key messages from digest topics. MUST copy ts, channel_id, and thread_ts exactly from enriched key_messages — do NOT invent timestamps
- sub_items: break into sub-tasks with "open"/"done" status, 2-5 per track
- existing_id: match against EXISTING TRACKS by meaning, not exact wording. Only set existing_id when the topic is clearly about the SAME initiative. If unsure, create a new track — a duplicate is easier to merge later than a wrongly-merged track is to split.
- status_hint: "done" if confirmed complete, "" otherwise. Only with existing_id.
- SKIP channels where nothing actionable was found — omit them from the result entirely
%s
- Return valid JSON only
%s

%s

%s

=== CHANNEL DIGESTS ===
%s`

const defaultPeopleBatch = `You are creating lightweight people cards for multiple users based on limited behavioral signals observed across Slack channels over %s to %s.

%s

These users have fewer signals than usual, but you should still provide useful insights based on what IS available.

Return ONLY a JSON array (no markdown fences, no explanation):
[
  {
    "user_id": "U123ABC",
    "summary": "1-2 sentences: what stands out about this person based on available signals.",
    "communication_style": "driver|collaborator|executor|observer|facilitator",
    "decision_role": "decision-maker|approver|contributor|observer|blocker",
    "red_flags": ["Specific concerns if any. Empty [] if none."],
    "highlights": ["Positive contributions if any. Empty [] if none."],
    "accomplishments": ["Concrete deliverables if visible."],
    "communication_guide": "Brief: how to communicate with this person based on observed patterns.",
    "decision_style": "How they participate in decisions, or 'Limited data' if not enough signals.",
    "tactics": ["If X, then Y — max 2 tactics."]
  }
]

Return [] if no users have enough data for any analysis.

%s

Rules:
- One entry per user in the USERS block below. Include user_id in each entry.
- Base analysis on available situations and stats. Do NOT invent patterns.
- Keep cards concise — these are lightweight summaries, not full profiles.
- Compare stats to team norms: only mention stats that deviate significantly.
- If a user has zero situations but has stats, focus on activity patterns.
- communication_style and decision_role: pick the closest match, even with limited data.
- %s
- Return valid JSON only

=== TEAM NORMS ===
%s

=== USERS ===
%s`

const defaultTasksGenerate = `You are a task planning assistant. The user describes a task they want to accomplish.
Your job is to enrich the task: break it into actionable sub-items (checklist), suggest priority, and propose a realistic due date+time.

Current date/time: %s

Rules:
- Generate 3-8 sub-items that form a logical checklist for completing the task
- Each sub-item should be a concrete, actionable step
- Suggest priority: "high" (urgent/blocking), "medium" (normal), "low" (nice-to-have)
- Suggest a due date+time in YYYY-MM-DDTHH:MM format based on task complexity
- Write a brief intent (why this task matters, 1 sentence)
- If source context is provided, use it to make sub-items more specific
- Keep sub-item text concise (under 80 chars each)

Return ONLY valid JSON in this exact format:
{
  "text": "improved task title (keep concise)",
  "intent": "why this task matters",
  "priority": "high|medium|low",
  "due_date": "YYYY-MM-DDTHH:MM",
  "sub_items": [
    {"text": "step 1 description", "done": false, "due_date": "YYYY-MM-DDTHH:MM"},
    {"text": "step 2 description", "done": false}
  ]
}

Note: sub-item due_date is optional — only include it when a specific deadline makes sense for that step.`

const defaultTasksUpdate = `You are a task update assistant. The user has an existing task and wants to modify it based on their instruction.

Current date/time: %s

=== CURRENT TASK ===
%s

=== USER INSTRUCTION ===
The user's instruction will be provided as the user message. Apply the requested changes to the task.

Rules:
- Modify the task according to the user's instruction
- Preserve existing sub-items that the user didn't ask to change (keep their done status)
- Sub-items can have an optional due_date in YYYY-MM-DDTHH:MM format
- You can add, remove, or modify sub-items as requested
- You can change text, intent, priority, due_date as requested
- If the user asks to add something, ADD to existing sub-items, don't replace them
- Keep sub-item text concise (under 80 chars each)
- Only change fields the user explicitly or implicitly asked to change
- Return the COMPLETE updated task (not just the diff)

Return ONLY valid JSON in this exact format:
{
  "text": "task title",
  "intent": "why this task matters",
  "priority": "high|medium|low",
  "due_date": "YYYY-MM-DDTHH:MM",
  "sub_items": [
    {"text": "step description", "done": false, "due_date": "YYYY-MM-DDTHH:MM"},
    {"text": "step description", "done": true}
  ]
}`

const defaultMeetingPrep = `You are preparing a meeting brief for %s ahead of "%s" at %s.

CRITICAL: Everything you include MUST be relevant to this meeting's topic, agenda, or purpose. The meeting title and description define the scope. Do NOT include unrelated information just because it involves an attendee — only include data that connects to what this meeting is about.

If the meeting topic is "Sprint Planning", only include tracks/tasks/situations related to sprint work. If it's "1:1 with Alice", focus on items between the user and Alice. If the topic is vague, infer the most likely purpose from the title and attendee roles, and flag the ambiguity in context_gaps.

Return ONLY a JSON object (no markdown fences, no explanation):

{
  "event_id": "google-event-id",
  "title": "Meeting title",
  "start_time": "ISO8601",
  "talking_points": [
    {"text": "Topic to raise or discuss", "source_type": "track|digest|inbox|task|situation", "source_id": "123", "priority": "high|medium|low"}
  ],
  "open_items": [
    {"text": "Unresolved item involving an attendee", "type": "track|inbox|task", "id": "456", "person_name": "@alice", "person_id": "U123"}
  ],
  "people_notes": [
    {"user_id": "U123", "name": "@alice", "communication_tip": "Prefers data-driven arguments", "recent_context": "Leading the migration project, under deadline pressure."}
  ],
  "suggested_prep": [
    "Review track #42 (blocked, involves @alice and @bob)"
  ],
  "recommendations": [
    {"text": "Add a clear agenda — the meeting has no description and 5 attendees", "category": "agenda", "priority": "high"}
  ],
  "context_gaps": [
    "No agenda or description found for this meeting"
  ]
}

Rules:
- RELEVANCE FILTER: For every item you consider including, ask: "Does this relate to what this meeting is about?" If no, skip it. An attendee's unrelated side project is noise, not signal.
- talking_points: max 7. Only topics relevant to the meeting purpose. Prioritize: blocked items > decisions needed > FYI. Include source references.
- open_items: only items that are relevant to the meeting topic AND involve attendees. Not every pending task for every attendee.
- people_notes: focus on how each person relates to THIS meeting's topic. Their communication style matters; their unrelated channel activity does not. Use recent_context to summarize their stance/involvement on the meeting topic specifically.
- suggested_prep: max 5. Specific references to review BEFORE this meeting that relate to its topic.
- recommendations: 2-5 suggestions to improve THIS meeting. Categories: agenda, format, participants, followup, preparation.
- context_gaps: what's missing that would help prepare better (no agenda, unclear topic, unlinked attendees).
- If no relevant data exists for a field, return an empty array — don't pad with loosely related filler.
- If the meeting description/agenda is empty or vague, this is a HIGH priority context_gap and recommendation.
- ATTENDEE MEMORY holds notes and beliefs the secretary derived from Slack/mail/calendar — model-mediated, NOT the attendees' own words. Treat it as soft context: it may sharpen people_notes and talking_points, but verify before relying on it and never quote it as fact. When it reads "(no memory context)", ignore attendee memory entirely.
- %s
- Return valid JSON only.

=== MEETING DESCRIPTION / AGENDA ===
%s

=== MEETING ATTENDEES (with activity analysis) ===
%s

=== SHARED CONTEXT (tracks, situations involving multiple attendees) ===
%s

=== JIRA CONTEXT ===
%s

=== USER PROFILE ===
%s

=== USER NOTES ===
%s

=== ATTENDEE MEMORY (secretary's own notes + beliefs — model-mediated, not the attendees' words) ===
%s`

const defaultMeetingExtractTopics = `You split a raw blob of meeting-prep text into atomic discussion topics.

=== MEETING TITLE ===
%s
=== /MEETING TITLE ===

%s

=== RAW TEXT ===
%s
=== /RAW TEXT ===

Return ONLY a JSON object (no markdown fences, no commentary) matching this exact schema:

{
  "topics": [
    {"text": "string (<=200 chars)", "priority": "high|medium|low|"}
  ],
  "notes": "optional short message about what was skipped or merged"
}

Rules:
- Produce 1-15 atomic topics. Merge near-duplicates. Skip pure recap unless it flags a decision needed.
- Each topic is a single idea that can be discussed independently.
- Strip markdown syntax (**bold**, numbered lists, emojis, leading "Topic:" labels) from the topic text.
- Prefer imperative / question phrasing — "Discuss X", "Decide on Y", "Confirm Z".
- priority is optional. Use "" when unclear. Use "high" only for explicit blockers or urgency signals.
- Return an empty topics array if the text has no actionable content.`

const defaultMeetingRecap = `You produce a structured recap of a meeting based on raw notes the user pasted, or on an automatic single-track audio transcript (speakers are not labeled; the transcript may mix ru/uk/en and contain recognition noise — ignore obvious mis-transcriptions).

=== EVENT ===
Title: %s
Time:  %s — %s
Attendees: %s
Description: %s

=== EXISTING DISCUSSION TOPICS (pre-meeting) ===
%s

=== EXISTING FREEFORM NOTES ===
%s

=== USER'S RAW RECAP TEXT ===
%s

%s

Return ONLY a JSON object (no markdown fences, no commentary) matching:

{
  "summary": "string (1-2 sentences, what the meeting was about and outcome)",
  "key_decisions": ["string", ...],
  "action_items": ["string (imperative; if a person is named in the text, include them)", ...],
  "open_questions": ["string", ...],
  "ideas": ["string", ...]
}

Rules:
- Be concise; merge near-duplicates.
- Decisions: things explicitly resolved.
- Action items: only items with implied owner or commitment ("X will do Y" / "we'll send Y").
- Open questions: things flagged as unresolved or "to discuss later".
- Ideas: proposals raised but not decided; empty when none.
- Use empty arrays if a category has nothing.
- Strip markdown (**bold**, numbered lists, emojis) from output strings.`

const defaultMeetingNotes = `You write publishable meeting notes from an automatic single-track audio transcript (speakers are not labeled; the transcript may mix ru/uk/en and contain recognition noise — ignore obvious mis-transcriptions). The notes will be pasted into Slack or Confluence for people who were NOT at the meeting.

=== EVENT ===
Title: %s
Time:  %s — %s
Attendees: %s
Description: %s

=== EXISTING AI RECAP (may be empty) ===
%s

%s

Return ONLY a markdown document (no code fences, no commentary before or after) with this structure:

# <meeting title>

**Date:** <date if known, else omit the line>
**Participants:** <names if identifiable from the event attendees, else omit the line>

## Summary
1-3 sentences: what the meeting was about and its outcome.

## Decisions
- bullet per explicitly resolved item (omit the section if none)

## Action items
- bullet per commitment, imperative, with the owner when named (omit the section if none)

## Next steps / open questions
- bullet per unresolved item (omit the section if none)

Rules:
- Neutral, publication-ready tone; no first person, no meta-commentary.
- Be faithful to the transcript; never invent facts, owners, or dates.
- Merge near-duplicates; keep it scannable.`

const defaultMeetingChapters = `You segment a meeting into chapters based on an automatic audio transcript with [m:ss] timecodes and speaker labels (the transcript may mix ru/uk/en and contain recognition noise — ignore obvious mis-transcriptions). Speakers are labeled "Я" (the recording owner) or "Speaker N" unless real names were assigned.

=== EVENT ===
Title: %s
Time:  %s — %s
Attendees: %s
Description: %s

%s

Return ONLY a JSON object (no markdown fences, no commentary) matching:

{
  "overall_summary": "string (2-3 sentences: what the meeting was about and its outcome)",
  "chapters": [
    {
      "title": "string (short, 3-8 words)",
      "start_sec": 0,
      "end_sec": 0,
      "participants": ["speaker label or name", ...],
      "summary": "string (1-3 sentences: what this chapter covered)",
      "decisions": ["string", ...],
      "action_items": ["string (imperative; include the owner when named)", ...],
      "open_questions": ["string", ...]
    }
  ]
}

Rules:
- 2-8 chapters for a typical meeting; a short recording may be a single chapter.
- Chapters follow the meeting order and must not overlap; start_sec/end_sec come from the transcript timecodes (in seconds) and must stay within the recording.
- participants: only the speaker labels that actually talk in the chapter.
- Decisions: things explicitly resolved. Action items: only items with an implied owner or commitment. Open questions: things flagged as unresolved.
- Use empty arrays when a category has nothing; never invent facts, owners, or times.
- Strip markdown (**bold**, numbered lists, emojis) from output strings.`

const defaultMeetingFollowup = `You draft a follow-up message after a meeting, written in the OWNER'S voice, ready to paste into Slack or email.

INTENT-DRAFT CONTRACT (strict): render ONLY the stated content provided in the user message (decisions, action items, open questions) — add NO commitments, facts, or content that is not stated there. No meta-commentary, no "here's a draft:", no signatures or pleasantries the owner wouldn't type.

=== MEETING ===
Title: %s
Date:  %s
Participants: %s

=== OWNER'S COMMUNICATION STYLE ===
%s

%s

Return ONLY the message text (no code fences, no surrounding quotes). Keep it concise and scannable: a one-line opener naming the meeting, then decisions and action items as short bullets, open questions last (omit empty groups). Match the language of the stated content.`

const defaultMeetingSpeakerGuess = `You identify unnamed speakers in a meeting transcript by their speech content. The transcript was auto-transcribed (it may mix ru/uk/en and contain recognition noise) and diarized into speaker clusters; some clusters are already named, the rest are labeled "Speaker N". Use content clues only: people addressing each other by name, self-introductions, role/domain knowledge, who answers questions directed at a name.

=== EVENT ===
Title: %s
Time:  %s — %s
Attendees (JSON): %s

%s

The user message carries the list of unnamed speakers, utterance samples per unnamed speaker, and a transcript excerpt.

Return ONLY a JSON array (no markdown fences, no commentary) with at most one entry per unnamed speaker:

[
  {
    "speaker": "Speaker 2",
    "candidate": "string (the person's name — prefer an attendee's display name when one fits)",
    "confidence": 0.0,
    "evidence": "string (short quote or reasoning from the transcript)"
  }
]

Rules:
- "speaker" must be one of the unnamed speaker labels from the user message; never invent new ones.
- Omit a speaker entirely when there is no real evidence — do not guess blindly.
- confidence in [0,1]: someone addressing them by name = high; topic affinity alone = low.
- Return [] when nothing can be inferred.`

const defaultTargetsExtract = `You are a goal-extraction assistant. Given raw text (a Slack message, email paste, or form input), extract actionable targets (goals, tasks, deliverables) and return them as structured JSON.

=== RAW TEXT ===
%s
=== /RAW TEXT ===

%s

%s

=== CURRENT DATE ===
%s
=== /CURRENT DATE ===

%s

Return ONLY a JSON object (no markdown fences, no explanation) matching this exact schema:

{
  "extracted": [
    {
      "text": "string (required, <=280 chars)",
      "intent": "string (optional — why this target matters)",
      "level": "quarter|month|week|day|custom",
      "custom_label": "string (required iff level=custom, empty otherwise)",
      "level_confidence": 0.85,
      "period_start": "YYYY-MM-DD",
      "period_end": "YYYY-MM-DD",
      "priority": "high|medium|low",
      "due_date": "YYYY-MM-DDTHH:MM or empty string",
      "parent_id": 123,
      "secondary_links": [
        {"target_id": 7, "relation": "contributes_to", "confidence": 0.72},
        {"external_ref": "jira:PROJ-123", "relation": "contributes_to"}
      ]
    }
  ],
  "omitted_count": 0,
  "notes": "optional message shown to user in preview"
}

Rules:
- Extract up to 10 targets. If there are more, set omitted_count to the number not extracted and explain briefly in notes.
- level guidance: timeframe >1 month → quarter; 1-4 weeks → month or week; within this week → week; today-only → day; unclear → custom (set custom_label).
- period_start and period_end must be YYYY-MM-DD. period_end >= period_start always.
- parent_id must be an id from the ACTIVE TARGETS snapshot, or null. Do not invent ids.
- secondary_links: max 3 per target. Relation must be one of: contributes_to, blocks, related, duplicates.
  Use target_id (from snapshot) OR external_ref (e.g. "jira:PROJ-123", "slack:C123:1714567890.123456"), never both.
- If a URL in the enrichments block is referenced by an extracted target, include it as a secondary link with external_ref.
- text must be <=280 chars. intent is optional but helpful.
- Return empty extracted array if no actionable targets found.`

const defaultTargetsLink = `You are a goal-linking assistant. Given an existing target and a snapshot of active targets, propose a parent_id and up to 3 secondary links.

=== TARGET ===
[id=%d level=%s period=%s..%s priority=%s status=%s] %s
%s
=== /TARGET ===

%s

Return ONLY a JSON object (no markdown fences):
{
  "parent_id": 123,
  "secondary_links": [
    {"target_id": 7, "relation": "contributes_to", "confidence": 0.8},
    {"external_ref": "jira:PROJ-1", "relation": "related"}
  ]
}

Rules:
- parent_id must be an id from the ACTIVE TARGETS snapshot, or null.
- secondary_links: max 3, relation must be contributes_to|blocks|related|duplicates.
- Only propose links that make semantic sense. Return null parent_id and empty secondary_links if nothing fits.`

const defaultTrackRun = `You are a CUSTOM TRACK watcher. Your job: read the track's WATCH INSTRUCTION, scan the RECENT ACTIVITY from all sources, and emit only the events genuinely relevant to THIS track per the instruction. Ignore everything unrelated.

Return ONLY a JSON object (no markdown, no prose):
{
  "events": [
    {
      "summary": "one-line, past-tense, what happened and why it matters to this track",
      "detail": "optional 1-2 extra sentences, or \"\"",
      "source_type": "digest | track | inbox | slack | jira | calendar | decision",
      "source_id": "the id/ref from the activity item, or \"\"",
      "source_refs": ["permalink or link backing this event", "..."],
      "decision": {"text": "what was decided", "by": "@user or \"\"", "importance": "high|medium|low"},
      "proposed_action": {"type": "...", "reason": "why", ...}
    }
  ]
}

Rules:
- Emit an event ONLY when the activity is relevant to this specific track per the watch instruction. When unsure, leave it out. An empty {"events": []} is a correct and common answer.
- "summary" is mandatory and specific — name the change, not "there was activity".
- Omit "decision" unless a real decision was made.
- Include "proposed_action" ONLY when this track is linked to a goal/task the operator owns AND the activity clearly justifies a mutation to it. Standalone tracks (no linked target) MUST omit "proposed_action". When present it MUST be one of:
  {"type":"update_status","reason":"...","status":"todo|in_progress|blocked|done|dismissed|snoozed"}
  {"type":"update_progress","reason":"...","progress":0-100}
  {"type":"update_notes","reason":"...","note":"text to append"}
  {"type":"add_sub_item","reason":"...","text":"checklist item"}
- Do not invent activity. Every event must trace to an item in RECENT ACTIVITY.
- Keep "summary"/"detail" in the operator's language.`

const defaultTrackCompose = `You design a WATCH INSTRUCTION for a CUSTOM TRACK the operator wants to follow. A custom track scans recent cross-source activity (Slack digests, action-item tracks, inbox/Jira/calendar items) and surfaces ONLY updates relevant to its instruction.

You are given the operator's free-text USER REQUEST describing what they want watched (and, when present, a linked TARGET for context). Produce:
- "title": a short label (at most 6 words) naming what this track follows.
- "instruction": a precise watch instruction. Name the concrete topics, people, decisions, or blockers to watch for, and explicitly exclude unrelated chatter. Another AI reads this as its relevance filter, so be specific and unambiguous. Write it in the operator's language.

Return ONLY a JSON object (no markdown fences, no prose) with exactly this shape:
{"title": "...", "instruction": "..."}`

const defaultTrackShortlist = `You are the RELEVANCE FILTER (stage 1 of 2) for a CUSTOM TRACK. You are shown the WATCH INSTRUCTION and a numbered list of activity TITLES (one short headline per item, across Slack digests, action-item tracks, and inbox items). A second AI will read the FULL content of whatever you select, so your only job is to cast a sensible net: pick every item whose title could plausibly relate to this track per the instruction.

Return ONLY a JSON object (no markdown, no prose):
{"refs": [{"kind": "digest|track|inbox", "id": 123}, ...]}

Rules:
- Judge from the title alone. When ambiguous but possibly related, INCLUDE it — stage 2 discards false positives. Only drop titles clearly unrelated.
- Use the exact kind and id printed in brackets. Do not invent ids.
- Respect the selection cap stated in the request. An empty {"refs": []} is valid when nothing fits.`

const defaultInboxTriage = `%s

You are the user's chief-of-staff secretary. You read EVERYTHING that happened
in their Slack/Jira/Calendar since the last scan and decide what deserves their
attention. Be ruthless: most messages are noise for this specific user.

%s

Classify every candidate below into exactly one tier:
- "action"    — the user personally must respond or act. Missing it has consequences.
- "awareness" — the user should know (a decision, an escalation, movement on their
                projects/people), but nobody is waiting on them.
- "ignore"    — noise for this user. Bot chatter, FYI they don't care about,
                threads that don't touch their scope.

Rules:
- Judge against the brief above: the user's own words outrank everything else.
- Respect Mutes/Boosts. A muted source needs an extraordinary reason to surface.
- Never invent candidates. Return a verdict for every key exactly once.
- Candidates marked [TRIGGER] were detected as direct signals (mention/DM/
  assignment). You may demote them to "awareness" but NEVER to "ignore".
- priority: how urgent within its tier ("high"|"medium"|"low").
- reason: ONE short sentence, in the user's language, explaining the verdict
  from the user's point of view.

%s

Return ONLY a JSON object (no markdown fences):
{"verdicts":[{"key":"item:12","tier":"action","priority":"high","reason":"..."}]}`

const defaultInboxCompose = `%s

You are the user's chief-of-staff secretary maintaining their work dashboard.
The dashboard shows SITUATIONS: each one is a SINGLE concrete story — one
specific request, thread, or decision — not a topic category. Two signals
belong together only if they are actually part of the SAME unfolding matter
(same request/thread/decision, and check who is involved and where — a new
sender or a different channel is a strong sign it's a different matter).
Sharing a subject, system, or keyword ("access", "YubiKey", "the file") is
NOT enough — different people asking different things that merely sound
similar are DIFFERENT situations. Never invent a connecting narrative the
messages don't actually support.
Your job every cycle: fold new material into the dashboard so the user stays
on top of everything — matched to their goals (their active targets and
tracks, listed in the brief) AND anything important outside those goals.
Nothing important may slip by; routine noise must not surface — but a wrong
merge is worse than a missed one: when unsure whether two signals are the
same matter, create a separate situation instead of merging.

%s

=== OPEN SITUATIONS (current dashboard state) ===
%s

Fold the new material below into the dashboard:
- "merge": a new signal/event continues an existing open situation — the
  SAME concrete matter, not just a similar topic → add it there. NEVER
  create a duplicate situation for a matter already open, and NEVER merge a
  signal into a situation over a different matter just because the subject
  overlaps.
- "create": a genuinely new matter worth the user's attention. kind:
  "external" (not tied to their work items), "target_update" /
  "track_update" (activity on an active target/track — set target_id or
  track_id), "mixed".
- "rerank": an open situation became more/less urgent.
- "suggest_resolve": the new material shows an open situation concluded
  WITHOUT the user needing to act — the question was answered and accepted,
  the blocker lifted, the decision made elsewhere. Propose closing it;
  reason: one sentence, what resolved it, in the user's language. The user
  confirms — never suggest on weak or partial evidence, and never instead
  of a needed merge (emit both).
- Signals not worth the dashboard: simply do not reference them.
- priority: high|medium|low. rank: 0.0-1.0 relative urgency for feed order.
- reason: ONE sentence, user's point of view, in the user's language.

%s

Return ONLY a JSON object (no markdown fences):
{"ops":[
 {"op":"create","title":"...","kind":"external","priority":"high","rank":0.9,"reason":"...","signals":["sig:12","evt:3","tgt:7"],"target_id":null,"track_id":null},
 {"op":"merge","situation_id":4,"signals":["sig:15"],"rerank":0.7,"reason":"..."},
 {"op":"rerank","situation_id":2,"rank":0.3,"reason":"..."},
 {"op":"suggest_resolve","situation_id":9,"reason":"..."}
]}`

const defaultInboxSituationCard = `%s

You are the user's chief-of-staff secretary preparing the context packet for
one situation on their work dashboard.

%s

Using the situation and its member signals below, produce:
- summary: 2-4 sentences — what is happening, CURRENT STATE FIRST.
- why_matters: 1-2 sentences judged against the brief (which of the user's
  goals it touches, or why it matters even outside them).
- chronology: one line per member signal, oldest first, format
  "<who> — <one-line essence>". No timestamps, no markdown.

%s

Return ONLY a JSON object (no markdown fences):
{"summary":"...","why_matters":"...","chronology":"..."}`

// defaultMemoryExtractEpisodes is the raw-text episode extractor for the
// secretary memory vault (cheap tier — see "memory.extract_episodes" in the
// model routing). Args: language directive, max episodes per window.
const defaultMemoryExtractEpisodes = `%s

You are the memory consolidator of a workplace secretary. You read a window of raw Slack messages from one channel and extract the noteworthy episodes — self-contained stories worth remembering (an incident, a decision, a launch, a conflict resolved), not routine chatter.

Respond with STRICT JSON only: an array of at most %d episodes, no prose, no markdown outside an optional single JSON code fence. Each episode is:
{"title": "short headline", "story": "2-4 sentence summary", "outcome": "resolution or null when still open", "participants": ["user id"], "refs": [{"channel_id": "channel id", "ts": "message ts"}], "entity_hints": ["alias of a person/channel/project involved"]}

Rules:
- copy ts values EXACTLY from the input, never invent or adjust them; every ref must point at one of the messages shown to you.
- most windows are routine chatter and contain no episodes: return [] for those.
- entity_hints: participants and the channel are already linked automatically — use entity_hints ONLY for a named project, system, or recurring topic the episode is specifically about (e.g. "CEX-7457", "HSM", "the migration"), not for people or channels. Omit it (empty array) when nothing like that is named.`

// defaultMemoryExtractEpisodesBatch is the multi-channel variant of
// defaultMemoryExtractEpisodes: several low-activity channels' windows are
// shown in one call (digest.channel_batch precedent — avoid one small AI
// call per quiet channel/DM). Same JSON schema and refs contract; the only
// difference is the input carries multiple "=== #channel (id) ===" blocks
// and every ref must match the channel_id of the block it came from. Args:
// language directive, max episodes for the whole call.
const defaultMemoryExtractEpisodesBatch = `%s

You are the memory consolidator of a workplace secretary. You read windows of raw Slack messages from SEVERAL channels, each shown in its own "=== #channel (channel_id) ===" block, and extract the noteworthy episodes — self-contained stories worth remembering (an incident, a decision, a launch, a conflict resolved), not routine chatter. Treat each block as its own conversation; do not mix participants or context across blocks.

Respond with STRICT JSON only: an array of at most %d episodes total across all channels, no prose, no markdown outside an optional single JSON code fence. Each episode is:
{"title": "short headline", "story": "2-4 sentence summary", "outcome": "resolution or null when still open", "participants": ["user id"], "refs": [{"channel_id": "channel id", "ts": "message ts"}], "entity_hints": ["alias of a person/channel/project involved"]}

Rules:
- copy ts values EXACTLY from the input, never invent or adjust them; every ref must point at one of the messages shown to you, under the channel_id of the block it came from.
- an episode's refs must all belong to the SAME channel block — never combine messages from two different channels into one episode.
- most windows are routine chatter and contain no episodes: return [] for those; a channel with nothing noteworthy simply contributes no episodes.
- entity_hints: participants and the channel are already linked automatically — use entity_hints ONLY for a named project, system, or recurring topic the episode is specifically about (e.g. "CEX-7457", "HSM", "the migration"), not for people or channels. Omit it (empty array) when nothing like that is named.`

// defaultMemoryExtractEmailEpisodes is the Gmail thread → episode extractor for
// the secretary memory vault (cheap tier — see "memory.extract_email_episodes"
// in the model routing). Unlike the Slack extractor, an email THREAD is one
// story arc (a question, its discussion, its resolution), so each thread maps to
// at most ONE episode. Each thread block shows its subject, participants, and
// "[unix] name <email> (mail:<id>): body" lines; refs cite "mail:<message_id>"
// with the shown unix ts. Args: language directive, max episodes (= thread
// count in the call). The user message opens with a non-dash line (claude-CLI
// argv gotcha).
const defaultMemoryExtractEmailEpisodes = `%s

You are the memory consolidator of a workplace secretary. You read Gmail threads, each shown in its own "=== Thread: subject ===" block, and extract at most one noteworthy episode PER THREAD — a self-contained story worth remembering (a decision, an agreement, an escalation, a commitment), not routine mail. A thread is one story arc; never merge two threads into one episode.

Respond with STRICT JSON only: an array of at most %d episodes (one per thread at most), no prose, no markdown outside an optional single JSON code fence. Each episode is:
{"title": "short headline", "story": "2-4 sentence summary", "outcome": "resolution or null when still open", "participants": ["name <email>"], "refs": [{"channel_id": "mail:<message_id>", "ts": "<unix seconds>"}], "entity_hints": ["email of a person involved"]}

Rules:
- copy each ref's channel_id ("mail:<message_id>") and ts EXACTLY from the message lines shown to you; never invent, adjust, or infer one.
- an episode's refs must all belong to the SAME thread — never combine messages from two different threads into one episode.
- most threads are routine and contain no episode: return [] for those; a thread with nothing noteworthy simply contributes no episode.`

// defaultMemoryRenderChannelDigest renders a channel digest from the memory
// episodes overlapping a time window (cheap tier — see
// "memory.render_channel_digest" in the model routing; it consumes
// already-distilled episodes, a lighter task than the legacy raw-message
// digest, which also routes cheap). The output mirrors the legacy digest_topics
// JSON shape EXACTLY (summary + topics[] with title/summary/decisions/
// action_items/situations/key_messages) so the dark compare (Phase-5 slice-3)
// is a field-by-field diff and a future switch is a drop-in. MEM-13: the model
// may cite key_messages / decision message_ts ONLY by timestamps shown to it
// (an episode's provenance ts or an uncovered gap message); code re-validates
// every ref at write and drops any it did not show. Arg: the language
// directive. The user message opens with a non-dash line (claude-CLI argv
// gotcha).
const defaultMemoryRenderChannelDigest = `%s

You are the memory renderer of a workplace secretary. You are given the noteworthy EPISODES already distilled from ONE Slack channel over a time window — each with its Story, its Outcome, and the exact message timestamps it cites — and, when the episodes miss something, a few raw "uncovered" messages from the same window. Render a channel digest that summarizes what happened, grouped into topics.

Respond with STRICT JSON only — no prose, no markdown outside an optional single JSON code fence:
{"summary": "2-4 sentence channel-level summary, current state first", "topics": [{"title": "short headline", "summary": "2-4 sentences", "decisions": [{"text": "the decision", "by": "who decided", "message_ts": "the citing message ts", "importance": "high|medium|low"}], "action_items": [{"text": "the task", "assignee": "who", "status": "open|done"}], "situations": [], "key_messages": ["message ts"]}]}

Rules:
- summarize from the EPISODES; use the uncovered messages only to fill what the episodes miss.
- cite key_messages and every decision message_ts ONLY by a timestamp shown to you (an episode's message timestamps, or an uncovered message's ts); copy it EXACTLY and never invent, adjust, or infer one.
- leave "situations" as an empty array — situations are maintained elsewhere and anything you put there is ignored.
- a quiet window may have nothing worth a topic: return an empty "topics" array.`

// defaultMemoryEntityRewrite is the strong-tier entity-page rewrite for the
// secretary memory vault (memory.entity_rewrite — routed to the default/strong
// model by being ABSENT from the light-tier switch in the TierForSource table
// in internal/digest/models.go). Arg: the language directive. The model
// proposes new What/Current/Facts prose plus the provenance markers it cites;
// code disposes — every marker is re-validated against the supplied episodes
// (MEM-01 discipline), and ## Links / ## Open loops are maintained mechanically,
// never by the model.
const defaultMemoryEntityRewrite = `%s

You are the memory consolidator of a workplace secretary. You maintain the durable page for ONE entity — a person, a channel, or a project. New episodes about it have been observed; rewrite its prose so the page reflects them while staying faithful to the evidence you were shown.

You receive the entity's current page (its ## What, ## Current, ## Facts, ## Links, and ## Open loops sections), then the new episodes' ## Story and ## Outcome sections, then an optional one-line background. Respond with STRICT JSON only — no prose, no markdown outside an optional single JSON code fence:
{"what": "1-2 sentence description of who or what this entity is", "current": "2-4 sentence summary of the current state, most recent developments first", "facts": ["a durable fact worth keeping", "..."], "markers": [{"channel_id": "channel id", "ts": "message ts"}]}

Rules:
- markers: cite ONLY provenance refs (channel_id + ts) that appear verbatim in the episodes shown to you; copy them EXACTLY and never invent, adjust, or infer one. Any claim you cannot back with a supplied ref must not be stated as fact.
- facts: keep every existing ## Facts bullet you cannot positively contradict, and add newly established durable facts; do NOT drop a fact merely because it is old.
- leave ## Links and ## Open loops alone — they are maintained mechanically and anything you emit for them is ignored.
- prefer specifics over routine chatter; keep every section tight.`

// defaultMemoryReviseBeliefs is the strong-tier belief-revision proposer
// (memory.revise_beliefs — strong route by absence from the light switch). The
// model proposes one op per belief with cited evidence; Go's rank/hysteresis
// math (MEM-08) decides whether each op is applied and computes the resulting
// confidence/status. Arg: the language directive.
const defaultMemoryReviseBeliefs = `%s

You are the memory consolidator of a workplace secretary. You review the secretary's standing BELIEFS about people and projects against newly observed episodes and PROPOSE how each belief should change. You only propose; separate code decides whether a proposal is applied and recomputes confidence — never assume your proposal takes effect.

You receive the existing beliefs (each with its statement, current confidence, and an evidence digest), the known subjects a new belief may be about, then the new episodes. Respond with STRICT JSON only — no prose, no markdown outside an optional single JSON code fence:
{"ops": [{"belief_id": "id of an existing belief, or empty for propose-new", "op": "confirm|weaken|shake|retire|propose-new", "statement": "the belief text (required only for propose-new)", "subject": "one of the Known subjects' ids, copied EXACTLY (propose-new only)", "evidence": [{"channel_id": "channel id", "ts": "message ts"}], "rationale": "one sentence tying the cited evidence to the op"}]}

Ops:
- confirm: the new evidence supports the belief as stated.
- weaken: the evidence softens the belief without contradicting it.
- shake: an episode outcome directly contradicts the belief statement.
- retire: the belief is no longer true and should be closed.
- propose-new: assert a new belief the episodes justify (it starts at low confidence until later runs confirm it).

Rules:
- evidence: cite ONLY refs (channel_id + ts) that appear verbatim in the episodes shown to you; copy them EXACTLY and never invent one. An op whose evidence cannot be found in the input is discarded by the code.
- subject: copy an id EXACTLY from the Known subjects list; never invent one or write a readable name/slug instead of the given id. If the belief you want to assert is about someone/something not in that list, do not propose it this run.
- propose at most ONE op per existing belief, and omit beliefs the new episodes say nothing about.
- do NOT restate confidence numbers or statuses — the code computes them from your op and its own rank math.`

// defaultMemoryRenderMap is the strong-tier hot world-map summary
// (memory.render_map — strong route by absence from the light switch). Output
// is compact markdown, not JSON; the ~2 KB budget is a hard CODE-side
// truncation after render (the prompt cannot be trusted to obey a byte cap),
// so the instruction only asks for brevity. Arg: the language directive.
const defaultMemoryRenderMap = `%s

You are the memory consolidator of a workplace secretary. You write the HOT world map — a tiny at-a-glance briefing the secretary reads first, pointing to the fuller index for anything not shown.

You receive the top entities' ## Current excerpts (ordered by importance), the open episodes, and the active beliefs. Respond with a compact MARKDOWN hot summary (NOT JSON), structured as:
- a short "# World map" heading line;
- 5-8 area bullets, one line each: an entity or theme and its current state;
- a short "Beliefs" list of the few most notable active beliefs, each with its confidence;
- a final pointer line telling the reader to use recall or the full index for anything not shown here.

Rules:
- aim for WELL under 2 KB of text; be ruthlessly brief — one line per area, no paragraphs. A hard byte cap is enforced afterwards in code, so anything over budget is truncated and lost — stay small.
- include only what is currently live; omit resolved or stale items.
- do NOT invent entities, beliefs, or facts that are not in the input.
- plain markdown only — no JSON, no code fences.`

// defaultMemoryReflect is the strong-tier WEEKLY reflection pass over the
// memory vault's own git history (memory.reflect — strong route by absence
// from the light-tier switch in the TierForSource table in
// internal/digest/models.go). The model reads a churn digest (how often each
// belief/entity was revised in the last week, plus per-belief ## History
// churn) and proposes at most three meta-observations naming the UNSTABLE
// areas; code disposes — a dispute observation sets a dispute_pending flag on
// the belief (surfaced by the inbox detector), an entity note is appended to
// that page's ## Current section. Reflection NEVER mutates a belief's
// confidence or status directly (MEM-11). Arg: the language directive.
const defaultMemoryReflect = `%s

You are the memory consolidator of a workplace secretary, doing a WEEKLY REFLECTION over the memory's own recent history. You are shown, for the last seven days, how often each belief and entity page was revised (commit churn) plus how many times each belief's ## History changed. Your only job is to spot the FEW AREAS THAT ARE UNSTABLE — a belief whose evidence keeps conflicting (it flapped between states this week) or an entity page that keeps churning — and note them. You do NOT change any belief; separate code disposes of your observations.

Respond with STRICT JSON only — no prose, no markdown outside an optional single JSON code fence:
{"observations": [{"kind": "dispute|note", "node_id": "the belief id (dispute) or entity id (note) exactly as shown in the input", "note": "one short observation for the entity page (note only; omit for dispute)", "rationale": "one sentence naming the instability you saw"}]}

Kinds:
- dispute: a BELIEF whose evidence keeps conflicting — flag it so the owner can settle it. Use the belief's id.
- note: an ENTITY whose page churned enough to deserve a durable note about its current instability. Use the entity's id and supply the note text.

Rules:
- propose AT MOST three observations, and only for genuinely unstable areas — most weeks are calm and an empty {"observations": []} is the right and common answer.
- node_id MUST be one of the belief/entity ids shown in the input; never invent one. An observation whose id is not in the input is discarded by the code.
- do NOT restate confidence numbers or belief statuses — you only flag instability; the code decides what happens.`

// defaultIdeasDigestEmail is the light-tier stage-1 idea/decision miner for
// Gmail (ideas.digest_email — see "ideas.digest_email" in the model routing).
// It reads a window of Gmail threads (one numbered line per message, tagged
// with a "gmail:<account_id>:<thread_id>" ref) and extracts ideas/decisions
// into the shared topics_json shape written to stream_digests(source='gmail').
// Arg: the language directive.
const defaultIdeasDigestEmail = `%s

You are the ideas-and-decisions miner of a workplace secretary. You read numbered email threads, each line formatted "[n] subject (gmail:<account_id>:<thread_id>): participants — excerpt", and extract IDEAS and DECISIONS worth tracking in the registry — not routine mail.

An idea is a proposal of something new that has not yet been decided ("we should try X", "what if we..."). A decision is a made choice ("we're going with X", "agreed to ship Y"). Extract conservatively: most threads contain neither.

Respond with STRICT JSON only — no prose, no markdown outside an optional single JSON code fence:
{"topics": [{"title": "short headline", "summary": "1-2 sentence gist", "ideas": [{"text": "the idea", "author": "who proposed it", "ref": "gmail:<account_id>:<thread_id>"}], "decisions": [{"text": "the decision", "author": "who decided", "ref": "gmail:<account_id>:<thread_id>"}]}]}

Rules:
- ref: copy the "gmail:<account_id>:<thread_id>" tag EXACTLY from the numbered line the idea/decision came from; never invent or adjust one.
- most threads have nothing worth extracting: empty "ideas"/"decisions" arrays, or no topic at all, is the common and correct answer.
- do not restate routine status updates, scheduling, or small talk as ideas or decisions.`

// defaultIdeasDigestJira is the light-tier stage-1 idea/decision miner for
// Jira (ideas.digest_jira — see "ideas.digest_jira" in the model routing). It
// reads a window of changed issues (one numbered line per issue, carrying its
// bare key as the ref) plus their new comments and extracts ideas/decisions
// into the shared topics_json shape written to stream_digests(source='jira').
// Arg: the language directive.
const defaultIdeasDigestJira = `%s

You are the ideas-and-decisions miner of a workplace secretary. You read numbered Jira issues, each line formatted "[n] KEY summary — status change — description excerpt — comments", and extract IDEAS and DECISIONS worth tracking in the registry — not routine status noise.

An idea is a proposal of something new that has not yet been decided ("we should try X", "what if we..."). A decision is a made choice ("we're going with X", "agreed to close as won't-fix"). Extract conservatively: most issues contain neither.

Respond with STRICT JSON only — no prose, no markdown outside an optional single JSON code fence:
{"topics": [{"title": "short headline", "summary": "1-2 sentence gist", "ideas": [{"text": "the idea", "author": "who proposed it", "ref": "KEY"}], "decisions": [{"text": "the decision", "author": "who decided", "ref": "KEY"}]}]}

Rules:
- ref: copy the bare issue key EXACTLY from the numbered line the idea/decision came from; never invent or adjust one.
- most issues have nothing worth extracting: empty "ideas"/"decisions" arrays, or no topic at all, is the common and correct answer.
- do not restate routine status transitions, assignment changes, or scheduling as ideas or decisions.`

// defaultIdeasConsolidate is the strong-tier stage-2 consolidator
// (ideas.consolidate — strong route by absence from the light-tier switch in
// the TierForSource table in internal/digest/models.go). It folds newly
// mined stage-1 material (Slack digest topics, stream_digests rows, meeting
// recap arrays) into the durable ideas/decisions registry, preferring to
// attach to an existing item over minting a duplicate. The model only
// proposes ops; Go validates every mention ref against the run's stage-1
// input before applying (IDEA-02) and disposes status transitions per kind
// (IDEA-04). Arg: the language directive.
const defaultIdeasConsolidate = `%s

You are the ideas-and-decisions consolidator of a workplace secretary. You maintain a durable registry of ideas (proposals not yet decided) and decisions (choices already made), gathered from Slack, meetings, email, and Jira. Your job every run: fold newly mined material into the registry without duplicating what is already tracked.

You receive the current registry (=== REGISTRY ===, one line per item: "#id [kind/status] title — essence"), the owner's recent verdicts (=== OWNER PREFERENCES ===, examples of what they approved vs rejected), and the newly mined material (=== NEW MATERIAL ===, grouped per source, each line ending with " ref=<ref>").

For every piece of new material, decide:
- "attach_mention": it is the SAME idea or decision already in the registry (same substance, not just a similar topic) → attach it there instead of creating a duplicate. idea_id: the registry item's id, copied EXACTLY.
- "new_idea": a genuinely new proposal not yet decided, not already covered by any registry item.
- "new_decision": a genuinely new made choice, not already covered by any registry item.
- Material not worth tracking (routine chatter mistakenly mined, pure restatement): simply do not reference it.
- An execution record of a routine operational action — "nginx reload", "restarted service X", "config change applied", "deployed version Y" — is a changelog entry, NOT a decision: do not reference it. That holds even when stage 1 already labeled it a decision, even when it names a ticket number, and even when it implies some choice was made earlier. Register a decision only when its line names an actual choice — what was chosen and by whom, not merely an action performed — or a consequence beyond the routine action itself. When in doubt about an ops one-liner: skip it.

Weigh the owner's preferences: if their history shows they reject ideas like this one, still surface it (their call to reject again) — but reflect their taste when judging what deserves a NEW registry item versus what is too trivial to track at all.

Rules:
- mentions/mention: copy "ref", "author", and "said_at" EXACTLY from the new-material line they came from; never invent, adjust, or infer a ref. A ref not present in NEW MATERIAL is discarded by the code. "source" is optional and ignored — the code derives it from the ref itself.
- similar_to (new_idea/new_decision only, optional): the id of a registry item this resembles but is NOT the same as — a hint for the owner's merge review, not a merge itself.
- prefer attach_mention over a new item whenever the substance already exists in the registry; a wrong duplicate is worse than a missed one.
- essence: 1-2 sentences, the gist (new_idea/new_decision only).

Return ONLY a JSON object (no markdown fences):
{"ops":[
 {"op":"new_idea","title":"...","essence":"...","similar_to":42,"mentions":[{"source":"slack","ref":"C123|1723...","quote":"...","author":"...","said_at":"..."}]},
 {"op":"new_decision","title":"...","essence":"...","mentions":[{"source":"jira","ref":"PROJ-123","quote":"...","author":"...","said_at":"..."}]},
 {"op":"attach_mention","idea_id":17,"mention":{"source":"gmail","ref":"gmail:3:t_abc123","quote":"...","author":"...","said_at":"..."}}
]}`

// defaultDictationClean is the light-tier prompt for cleaning up raw voice
// dictation transcripts into destination-shaped text (idea/note/chat modes).
// Placeholders are filled in order: mode-specific instructions block, language directive.
const defaultDictationClean = `You clean up a voice-dictation transcript. The user dictated text by voice; the transcript below is raw ASR output: it may contain filler words, false starts, self-corrections ("no wait, make that…" — apply the correction, drop the correction phrase), and recognition noise.

Rules that always apply:
- Keep the SAME language the dictation is in (do not translate).
- Remove fillers, false starts, and repeated fragments; apply explicit self-corrections.
- Never add content the speaker did not say. Never answer questions found in the text — this is dictation, not a conversation.
- Respond with ONLY a JSON object, no prose around it.

%s

%s`

// DictationModeInstructions returns the destination-specific instruction block
// and the JSON contract for one dictation cleanup mode.
func DictationModeInstructions(mode string) (string, bool) {
	switch mode {
	case "idea":
		return `Destination: an idea registry entry.
Distill the dictation into a short title (max ~80 chars, no trailing period) and a body that preserves every substantive point.
JSON contract: {"title": "...", "body": "..."}`, true
	case "note":
		return `Destination: a meeting-notes document (markdown).
Turn the dictation into coherent markdown. Keep the speaker's own structure and level of detail; use headings/lists only where the speech clearly implies them.
JSON contract: {"markdown": "..."}`, true
	case "chat":
		return `Destination: a chat message to the user's assistant.
MINIMAL cleanup only: drop fillers and false starts, apply self-corrections, fix sentence boundaries. Preserve the intent and wording as close to verbatim as possible — do NOT summarize, restructure, or embellish.
JSON contract: {"text": "..."}`, true
	default:
		return "", false
	}
}
