# Connections tab (2026-10-25, board #899)

Every account Watchtower reads from, and the assistant's Quick Connections, in one tab of the main window. Owner-approved design: ask #390. Replaces the Settings → Connections list, the Search tab and the Boards tab.

## Navigation

- `SidebarDestination.connections` (raw value `connections`, icon `powerplug`) is the first TOOLS item: Connections, Usage, MCP Server. No feature or source gate. `EmptyStateCopyTable.exempt` lists it: the overview always shows a card per service.
- `search` and `boards` are gone from `SidebarDestination`. A stored raw value of theirs (`sidebar.hiddenItems`) decodes to nil and hides nothing; a `watchtower-nav://search|boards` link is not a visible screen, so it is plain text and does nothing. The selected tab is not persisted, so there is no remembered selection to fall back from. Test: `ConnectionsTabTests.testRemovedTabsInStoredValuesAreIgnored`.
- `AppState.selectedConnection: ConnectionService?` holds the open service (nil = the overview). `AppState.openConnections(_:)` selects the tab and the service; callers outside the main window (Settings' **Open Connections**) also call `bringMainWindowForward()`.
- Every former way into Settings → Connections or the Boards tab lands here: the sidebar's "+ Connect…" row, an empty state's or Home's **Connect** (`ConnectionService(readinessSource:)`: Slack, Calendar, Jira, Linear; a source naming several opens the overview), **Choose Jira boards** and Home's Jira card (Jira), a day plan's Jira item, the `connect_jira_board` card's Open, the Inbox's and Your day's **Open Connections**, a purge notice or banner (`openAccountConnection(source:)`), an `openSettings("connections")` empty-state action. The Settings window opens on General; its Connections tab only shows **Open Connections**.
- The chat prompt's screen list (`appGuideNavRule`) names `connections` and no longer `search` or `boards`.

## Overview and detail

- `ConnectionsTabView` shows `ConnectionsOverview` (over `ConnectionsOverviewContent`, a pure view of `[ConnectionSummary]`) or `ConnectionsDetailSplit`: the service list (Sources, Tools for AI) beside the existing detail views from `Views/Settings/` (Slack, Google, Email, Calendar, Jira, Linear, Quick Connections), reused unchanged, with **All Connections** back to the overview and the shared `ConfigSaveBar`.
- The tab re-reads every account view model on appear, and the sidebar does on every selection change (`refreshConnectionAccounts`), since the daemon and the CLI write accounts from another process.
- The overview: a banner per service that needs the owner (**Reconnect** opens the service), a card per source (status dot or policy lock, account count, one status line) and the Quick Connections card under TOOLS FOR AI. **Connect…** is a menu of the services the policy allows.

## One status rule

- `ConnectionSummary` builds a service's status with `ConnectionStatusLogic.enabledFilteredStatus` over `ConnectionAccountState`s (services without a per-account switch pass `enabled: true`, which gives `status(okFlags:)`'s answer). `problems` are the enabled accounts that are not OK; a problem's text is the account's error, else its status ("access revoked", "data deleted…").
- `needsAttention` = status `.error` and the source not blocked by the organization's policy (#608): the owner cannot reconnect a blocked source. The banners and the sidebar badge (`AppState.connectionsAttentionCount`, red) both use it, counting services, not accounts. The badge replaced the sidebar's "Jira connected" line and its rail icon.

## State that survives navigation

- `AppState.slackAuthFlow` (`SlackAuthFlowState`) holds an in-flight Slack connect/reconnect/disconnect, so it survives switching services and leaving the tab (it lived on the Settings tab before).
- `AppState.sharedConfig` is the one in-memory `ConfigService` both the Settings window and the tab edit, so neither saves a stale copy over the other's change. Lazy; a test sets its own before first use.

## Jira: the Boards tab's sections

`JiraConnectionDetail` shows, once a site is connected, the Boards tab's sections after Sites: **Boards** (`JiraBoardsSettingsView`), the Confluence spaces per site, **Jira Features**, **User Mapping**, **Sync**. A board's profile and the features detail open in place (`JiraDetailItem`) with **Jira** to go back. Test: `ConnectionsTabTests.testJiraDetailHoldsTheBoardsOnceASiteIsConnected`.

## Search tab removal

The Search tab (Slack FTS results, the guide Help block, **Ask in chat**, the #892 index-rebuild line) is gone with `SearchViewModel`, `GuideQueries` and `SearchQueries.search`/`messagesIndexRebuildPending`. The knowledge index, `search_knowledge` and the CLI stay; `SearchQueries.sanitizeFTS5Query` stays for Memory. Home's Knowledge search card opens AI Chat.

## Tests

`make test-swift FILTER='ConnectionsTabTests|HomeLinkTests|SidebarSectionTests|EmptyStateCopyCoverageTests|NotificationRouteTests'`; shots `connections-overview` and `connections-blocked` in `DesignShotCatalog`.
