# Onboarding Flow — Watchtower Desktop

## High-Level Decision Tree

```
App Launch
       │
       ▼
  ┌─────────────┐     no DB / no config
  │  AppState    │─────────────────────────┐
  │  initialize()│                         │
  └──────┬───────┘                         ▼
         │                     ┌──────────────────────────────┐
    DB found                   │   OnboardingView             │
         │                     │   (Welcome Flow — 4 steps)   │
         ▼                     └──────────────────────────────┘
  checkNeedsOnboarding()
         │
    onboarding_done?
    ┌────┴────┐
    │  true   │  false
    ▼         ▼
 MainNav   OnboardingChatFlow
           (Chat Flow only)
```

---

## Path 1: Welcome Flow (first launch, no DB) — `OnboardingView`

`NavigationRoot`: no `isDBAvailable` → `OnboardingView`.

Full linear flow with 4 steps:

```
Step 1: Connect → Step 2: Settings → Step 3: Claude Check → Step 4: Sync + Chat
                                                                        │
                                                              ┌─────────┴──────────┐
                                                              │  Role Questionnaire │
                                                              │  (quick-reply chat) │
                                                              ├─────────────────────┤
                                                              │  AI Conversation    │
                                                              │  (free-form chat)   │
                                                              ├─────────────────────┤
                                                              │  Team Form          │
                                                              ├─────────────────────┤
                                                              │  Generating context │
                                                              └─────────────────────┘
```

### Step 1: Connect (Slack OAuth)

- Privacy notice: "Your data never leaves your Mac"
- Button "Connect to Slack" → launches browser OAuth flow (only on button press, no auto-open)
- OAuth callback via localhost HTTPS server (port 18491)
- Success page shows "Open Watchtower" button (no auto-redirect via JS)
- App handles `watchtower-auth://` URL scheme via `onOpenURL` — brings existing window to front
- If `config.yaml` already exists (repeat launch) → auto-skip to Step 2

**Key files:**
- `Navigation.swift` → `connectStep`, `startBrowserOAuthFlow()`
- `WatchtowerApp.swift` → `onOpenURL` handler
- `internal/auth/oauth.go` — OAuth server, success/error pages

### Step 2: Settings

| Setting | Options |
|---|---|
| Language | English / Ukrainian / Russian |
| AI Model | Fast (Haiku) / Balanced (Sonnet) / Quality (Opus) |
| History Depth | 1 / 3 / 5 / 7 days (or custom) |
| Sync Frequency | 5m / 15m / 30m / 1h |
| Notifications | Toggle on/off |

Saves to `config.yaml` via `watchtower config set` → advances to Step 3.

**Key files:**
- `Navigation.swift` → `settingsStep`, `applySettingsAndSync()`, `ModelPreset`, `PollPreset`

### Step 3: AI Setup (Claude Check)

Three branches:

1. **Claude CLI not found** → installation instructions (`npm install -g @anthropic-ai/claude-code`), browse for manual path, skip option
2. **Claude found** → automatic health check (`claude -p "respond with: OK" --model <selected>`)
   - Success → auto-advance to Step 4 (after 1.5s)
   - Error → diagnostics + retry
3. **Health passed** → green checkmark, then auto-advance

**Diagnostics map:**
- `not authenticated` / `unauthorized` → "Run `claude` in Terminal, complete login"
- `model` + `access`/`permission` → "Try a different AI model in Settings"
- `rate limit` / `overloaded` → "Wait and retry"
- `network` / `connection` → "Check internet connection"

**Key files:**
- `Navigation.swift` → `claudeStepView`, `runClaudeHealthCheck()`, `diagnoseClaudeError()`

### Step 4: Sync + Chat (parallel)

**Sync and chat run simultaneously.** The user fills in their profile while data syncs in the background.

Internal phases (`OnboardingChatPhase`):

```
chat → waitingForSync / teamForm → generating → done
```

Sync progress shown as compact banner at the bottom of the chat view. If chat finishes before sync — shows "Waiting for sync..." screen.

#### 4a. Role Questionnaire (quick-reply buttons in chat)

Questions appear as assistant chat bubbles. User answers via quick-reply buttons (shown instead of text input).

```
[AI]  Let's understand your role. Do people report to you?
                                            [Yes] [No]

→ User taps "Yes"

[You] Yes
[AI]  Do you determine strategy or vision for your area?
                                            [Yes] [No]

→ User taps "No"

[You] No
```

Branching logic:

- **Q1**: "Do people report to you?" → Yes / No
- **Q2a** (if Q1=Yes): "Do you determine strategy/vision for your area?" → Yes / No
- **Q2b** (if Q1=No): "Your influence comes mainly through..." → Expertise & authority / Solving tasks
- **Q3** (if Q1=Yes AND Q2a=Yes): "Do you manage other managers?" → Yes / No

Result → one of 5 roles:

| Q1 | Q2 | Q3 | Role |
|---|---|---|---|
| Yes | Yes (strategy) | Yes | **Top Management** |
| Yes | Yes (strategy) | No | **Direction Owner** |
| Yes | No | — | **Middle Management** |
| No | Expertise | — | **Senior IC / Expert** |
| No | Tasks | — | **IC / Specialist** |

**Key files:**
- `OnboardingChatViewModel.swift` → `startQuestionnaire()`, `answerRoleQ1()`, etc.
- `UserProfile.swift` → `RoleDetermination`, `RoleLevel`

#### 4b. AI Conversation (free-form)

After the last question is answered, `initiateChat()` fires automatically:
- Sends a hidden prompt to Claude with the determined role context
- AI streams its first message — acknowledges the role, asks about team/pain points
- Text input replaces the quick-reply buttons
- AI asks 2-4 questions (one at a time) about:
  1. Team — what team they're on
  2. Pain Points — what problems they face with Slack
  3. Track Focus — what to monitor (role-dependent)
- "Continue" button appears after ≥1 user message (for impatient users)

**Auto-completion:** AI appends `[READY]` marker when it has gathered enough info. The app strips the marker from displayed text, sets `chatReady = true`, and auto-transitions to team form.

**Key files:**
- `OnboardingChatViewModel.swift` → `initiateChat()`, `send()`, `stripReadyMarker()`, `chatReady`
- `OnboardingChatView.swift` → `onChange(of: chatReady)`

#### 4c. Team Form

- **Role** (text field, prefilled from chat)
- **Team** (text field, prefilled from chat)
- **My Reports** — multi-select SlackUserPicker (from synced users)
- **I Report To** — single-select SlackUserPicker
- **Key Peers** — multi-select SlackUserPicker
- Shows "Waiting for Slack sync to load users..." if `allUsers` is empty
- Button "Done" (Cmd+Return)

**Key files:**
- `OnboardingTeamFormView.swift`

#### 4d. Generating

1. `generatePromptContext()` — AI generates 3-5 sentence personalization context
2. `markOnboardingDone()` — sets `onboarding_done = 1` in DB
3. `backgroundTaskManager.startPipelines()` — kicks off digest/tracks pipelines
4. `onRetry()` → `appState.initialize()` → DB reopened → MainNavigationView

**Key files:**
- `OnboardingChatViewModel.swift` → `generatePromptContext()`, `markOnboardingDone()`

---

## Path 2: Re-onboarding (DB exists, incomplete) — `OnboardingChatFlow`

If DB exists but `onboarding_done = false` → `needsOnboarding = true` → `OnboardingChatFlow`.

**Skips Steps 1-3** (OAuth, Settings, Claude check already done). Goes straight to chat:

```
Chat (4a questionnaire + 4b AI conversation) → Team Form (4c) → Generating (4d)
```

On completion: `appState.completeOnboarding()` → MainNavigationView.

**Key files:**
- `OnboardingChatFlow.swift`

---

## Path 3: Re-run from Settings

`ProfileSettings` → "Re-run Onboarding" button → `appState.startOnboarding()` → `needsOnboarding = true` → Path 2.

**Key files:**
- `ProfileSettings.swift` → `onboardingSection`

---

## Data Model: `user_profile` table

| Field | Source | Type |
|---|---|---|
| `slack_user_id` | Workspace sync | TEXT (unique) |
| `role` | Questionnaire + chat parsing | TEXT |
| `team` | Chat parsing + team form | TEXT |
| `responsibilities` | (reserved) | JSON array |
| `reports` | Team form | JSON array of Slack user IDs |
| `peers` | Team form | JSON array of Slack user IDs |
| `manager` | Team form | Slack user ID |
| `starred_channels` | Post-onboarding (Settings) | JSON array |
| `starred_people` | Post-onboarding (Settings) | JSON array |
| `pain_points` | Chat parsing | JSON array |
| `track_focus` | Chat parsing | JSON array |
| `onboarding_done` | Completion flag (0→1) | INTEGER |
| `custom_prompt_context` | AI-generated personalization | TEXT |

---

## How the Profile is Used Downstream

### 1. Role-Aware Prompts (Go backend)

`prompts.Store.GetForRole(id, role)`:
- Tries role-specific prompt variant first (e.g., `tracks.extract_direction_owner`)
- Falls back to standard prompt if no variant exists
- Prepends `RoleInstructions[role]` context to all prompts

**Key files:**
- `internal/prompts/store.go` → `GetForRole()`
- `internal/prompts/role_variants.go` → `RoleInstructions` map

### 2. All Pipelines Get Personalized Prompts

- `internal/digest/pipeline.go` — digest generation
- `internal/tracks/pipeline.go` — track extraction
- `internal/analysis/pipeline.go` — people analytics

### 3. AI Chat Personalization

`custom_prompt_context` is injected into the system prompt for the conversational AI chat.

### 4. Team Graph for Tracks

Reports / manager / peers data is used for ownership assignment in the tracks pipeline.

---

## File Index

| File | Purpose |
|---|---|
| `WatchtowerApp.swift` | App entry, `onOpenURL` handler for `watchtower-auth://` scheme |
| `Navigation.swift` | `NavigationRoot`, `OnboardingView` (4-step wizard), `OnboardingStep` enum |
| `OnboardingChatFlow.swift` | Simplified flow controller for Path 2 (chat → team form → generating) |
| `OnboardingChatView.swift` | Unified chat UI: role questions (quick-reply buttons) + AI conversation |
| `OnboardingChatViewModel.swift` | ViewModel: questionnaire, chat, role determination, profile parsing, prompt generation |
| `OnboardingTeamFormView.swift` | Team picker form (reports, manager, peers) |
| `AppState.swift` | `needsOnboarding`, `checkNeedsOnboarding()`, `completeOnboarding()` |
| `ProfileSettings.swift` | "Re-run Onboarding" button, profile editing |
| `UserProfile.swift` | `RoleLevel` enum, `RoleDetermination` struct, `UserProfile` model |
| `ProfileQueries.swift` | DB operations for user_profile |
| `internal/auth/oauth.go` | OAuth localhost server, success/error pages |
| `internal/prompts/store.go` | `GetForRole()` — role-aware prompt loading |
| `internal/prompts/role_variants.go` | `RoleInstructions` — per-role context |
| `internal/db/schema.sql` | `user_profile` table definition |
| `internal/db/profile.go` | Go-side profile DB operations |
