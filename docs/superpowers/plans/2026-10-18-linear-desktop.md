# Linear Plan 2/3 — lane 4: Desktop (P5)

Spec: `docs/superpowers/specs/2026-10-15-linear-integration-design.md` §3.5 and the
Desktop row of §6. Board target #691. No migration, no Go change (the CLI already
has `linear accounts --json` with `auth`, `linear teams --json`,
`teams select|deselect`, `add|login --api-key` reading stdin, `--app-return`).

## Tasks

1. **Core: sources, readiness, onboarding plan** (WatchtowerCore, Tests/Core)
   - `ConnectedSources.linear` (non-removed `linear_accounts` row), `SidebarSource.linear`;
     Blockers shows with Jira or Linear; Inbox/Catch-Up accept Linear; `.anySource`
     counts Linear.
   - `ReadinessFeature.linear` (no switch, no pipeline run, content `linear_issues`,
     source `ReadinessSource.linear`), `FeatureReadiness.trackerReadiness(jira:linear:)`
     for the tracker-neutral tabs; Home: no "Connect Linear" row (the Jira row stays the
     tracker prompt), a Linear card once connected.
   - `OnboardingConnectSource.linear` after Jira for Tasks & Jira;
     `SourceConnectPrompt` treats Linear as the tracker kind.
   - Tests: FeatureReadinessTests / OnboardingConnectPlanTests / SidebarVisibility /
     SourceConnectPrompt / GettingReady cases.
2. **Core: `TrackerIssue` + `TrackerQueries`** over `tracker_issues`, `tracker_iterations`,
   `jira_issue_links` + `linear_relations`: blocked, stale, block links by key, issue by
   key, container (epic/project) progress, active iteration stats, issue/project search
   for mentions. Tests over mixed Jira + Linear rows.
3. **Desktop screens on the views**: Blockers (`BlockerMapViewModel`, card links from the
   view's `url`), Epic / Project progress + Active iterations in the weekly digest,
   chat mention search (`ChatEntityKind.linearIssue`, `MentionCandidate.Kind.linear`,
   token `linear:<KEY>`). Releases, Boards, Project Map, Workload stay Jira.
   `JiraQueries` slack-link reads untouched (lane 2).
4. **Settings → Linear + onboarding card**: `LinearAccountsViewModel` (AppState-owned;
   accounts from `linear accounts --json`, OAuth `add --app-return` with Cancel,
   API key `add --api-key` with the key on stdin, Re-login, enable/disable/remove,
   teams via `teams --json` + `teams select|deselect` with `--account`),
   `LinearConnectionDetail`, `AddLinearAccountView` (shared with onboarding),
   `ConnectionService.linear`. VM tests with stand-in CLIs.
5. **Docs**: `docs/features/linear.md` (Desktop section), `first-run.md` /
   `onboarding-v2.md` notes, user guide pages per `docs/guide/WRITING.md`.

## Contracts

No inventory contract changes. Go↔Swift dual paths: `ConnectedSources` mirrors the
account tables only; the readiness content table `linear_issues` is what the Go
connector writes. `linear accounts --json` keys pinned by the Swift decoder test.
