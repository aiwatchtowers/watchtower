# Connections tab (2026-10-25, board #899)

Every account Watchtower reads from, and the assistant's Quick Connections, in one tab of the main window. Owner-approved design: ask #390. Replaces the Settings → Connections list, the Search tab and the Boards tab.

## Navigation

- `SidebarDestination.connections` (raw value `connections`, icon `powerplug`) is the first TOOLS item: Connections, Usage, MCP Server. No feature or source gate. `EmptyStateCopyTable.exempt` lists it: the overview always shows a card per service.
- `search` and `boards` are gone from `SidebarDestination`. A stored raw value of theirs (`sidebar.hiddenItems`) decodes to nil and hides nothing; a `watchtower-nav://search|boards` link is not a visible screen, so it is plain text and does nothing. The selected tab is not persisted, so there is no remembered selection to fall back from. Test: `ConnectionsTabTests.testRemovedTabsInStoredValuesAreIgnored`.
- `AppState.selectedConnection: ConnectionService?` holds the open service (nil = the overview). `AppState.openConnections(_:)` selects the tab and the service; callers outside the main window (Settings' **Open Connections**, a purge notification through `openAccountConnection`) also call `bringMainWindowForward()`. A sidebar click on Connections and a `watchtower-nav://connections` link open the overview. The service list never deselects: only **All Connections** goes back.
- Every former way into Settings → Connections or the Boards tab lands here: the sidebar's "+ Connect…" row, an empty state's or Home's **Connect** (`ConnectionService(readinessSource:)`: Slack, Calendar, Jira, Linear; a source naming several opens the overview), **Choose Jira boards** and Home's Jira card (Jira), a day plan's Jira item, the `connect_jira_board` card's Open, the Inbox's and Your day's **Open Connections**, a purge notice or banner (`openAccountConnection(source:)`), an `openSettings("connections")` empty-state action. The Settings window opens on General; its Connections tab only shows **Open Connections**.
- The chat prompt's screen list (`appGuideNavRule`) names `connections` and no longer `search` or `boards`.

## Overview and detail

- `ConnectionsTabView` shows `ConnectionsOverview` (over `ConnectionsOverviewContent`, a pure view of `[ConnectionSummary]`) or `ConnectionsDetailSplit`: the service list (Sources, Tools for AI) beside the existing detail views from `Views/Settings/` (Slack, Google, Email, Calendar, Jira, Linear, Quick Connections), reused unchanged, with **All Connections** back to the overview and the shared `ConfigSaveBar`.
- The tab re-reads every account view model on appear (`refreshConnectionAccounts`), since the daemon and the CLI write accounts from another process. For the badge elsewhere, a sidebar click re-reads them at most once a minute (`refreshConnectionAccountsIfStale`, `connectionAccountsReadAt`, an injectable `now`); a click onto Connections leaves it to the tab.
- The related-features offer after a connect (`FeatureSuggestionSheet`) is presented over the main window (`FeatureSuggestionPresenter` on `MainNavigationView`), no longer from Settings.
- The overview: a banner per service that needs the owner (**Reconnect** opens the service), a card per source (status dot or policy lock, account count, one status line) and the Quick Connections card under TOOLS FOR AI. **Connect…** is a menu of the services the policy allows, ending with **Set up for my company** (the wizard page) and **Connect with a company code** (the Companies zone's field): `CompanyConnectionsPresentation.connectMenuCompanyActions` → `AppState.performConnectMenuCompanyAction`.

## One status rule

- `ConnectionSummary` builds a service's status with `ConnectionStatusLogic.enabledFilteredStatus` over `ConnectionAccountState`s (services without a per-account switch pass `enabled: true`, which gives `status(okFlags:)`'s answer). `problems` are the enabled accounts that are not OK; a problem's text is the account's error, else its status ("access revoked", "data deleted…").
- A service whose accounts could not be read (its view model not loaded, or its read failed with nothing listed, e.g. no CLI for Linear) is `unknown`: "Couldn't read accounts", a gray dot, no pitch and no badge.
- `needsAttention` = status `.error` and the source not blocked by the organization's policy (#608): the owner cannot reconnect a blocked source. The banners and the sidebar badge (`AppState.connectionsAttentionCount`, red) both use it, counting services, not accounts. The badge replaced the sidebar's "Jira connected" line and its rail icon.

## State that survives navigation

- `AppState.slackAuthFlow` (`SlackAuthFlowState`) holds an in-flight Slack connect/reconnect/disconnect, so it survives switching services and leaving the tab (it lived on the Settings tab before).
- `AppState.slackConnectListener` (the `slack connect serve` child), `slackConnectFlow` (`SlackConnectFlowModel`) and `slackAppSetup` (`SlackAppSetupModel`) hold the Slack connect flow and the company setup, so a run survives closing its sheet, switching services and leaving the tab ([slack-full.md](slack-full.md)).
- `AppState.sharedConfig` is the one in-memory `ConfigService` both the Settings window and the tab edit, so neither saves a stale copy over the other's change. Lazy; a test sets its own before first use. Both re-read config.yaml on appear unless an edit awaits Save (`reloadUnlessEdited`, `hasUnsavedEdits` compares the settings fields by reflection with what the last reload or save left).

## Slack: the mode pane (plan B, #1709)

`SlackConnectionDetail` is no longer a `Form`: `SettingsSection`s in a `ScrollView`, top to bottom the shared-app banner, **Slack mode** (chip, summary, Live block), the company setup's record rows, **Connect your workspace's app** (MDM rows, the link-or-code field, **Set up for my company**, the port-busy line; folded behind **Connect another workspace…** in Full), then **Slack Workspaces** (**Add Slack Account** only while the build bakes a Slack app, `builtin_app`), the legacy Workspace block and Reaction commands. The overview's Slack card gets a `ConnectionSummary.notice` "Shared app retiring" under its status line while an account syncs through the retired shared app: a notice, never `needsAttention` or a badge. Strings and states: [slack-live.md](slack-live.md) (mode, Live block) and [slack-full.md](slack-full.md) (setup, connect, banner).

## Companies zone and grouped accounts (company setup, #1887)

The overview has a **Companies** zone above Sources (`CompaniesZone` over `CompaniesZoneModel` on `AppState.companiesZone`, state from `CompanyConnectionsPresentation.zone`): a loading line, a read failure with **Try again** (never "no company"), the empty invitation, or one card per stored company (managed first; "N of M services connected", **Not connected: …**, a Replace's **Re-login** in `Tone.error`, **Connect the rest**, or **Connect all** for an MDM company with nothing connected); a draft's "Setup in progress: …" line with **Continue setup**; the quiet **Set up for my company** and **Connect with a company code** (the code field opens by itself while port 18551 is busy). The wizard opens as a page in the detail area (`AppState.companySetup`). Google, Jira, Linear, Email and Slack details list accounts through `CompanyAccountGroups` (one group per company, then own project, API tokens or keys, the shared app, **Other accounts**) with `companyRowStatus` lines; the Google and Jira details show the retirement banners and the policy lock cards; Jira's empty state ends with a quiet **Set up for my company**. Email → **Add Account** → **Connect Gmail** on the public build closes the sheet and opens the Google detail (`AppState.connectGmail`, `CompanyConnectionsPresentation.gmailRoute`): on the own Google project page, unless a stored company has a Google app, own projects are locked or the company files are unread. The **Add Google Account** sheet (Calendar card, onboarding) shows Gmail switched off with `sharedGoogleGmailNote`; a flavored build keeps the switch, since its baked client is its company's app (Go's `googleOnSharedClient`). Details: [company-setup.md](company-setup.md).

## Jira: the Boards tab's sections

`JiraConnectionDetail` shows, once a site is connected, the Boards tab's sections after Sites: **Boards** (`JiraBoardsSettingsView`), the Confluence spaces per site, **Jira Features**, **User Mapping**, **Sync**. A board's profile and the features detail open in place (`JiraDetailItem`) with **Jira** to go back. Test: `ConnectionsTabTests.testJiraDetailHoldsTheBoardsOnceASiteIsConnected`.

## Search tab removal

The Search tab (Slack FTS results, the guide Help block, **Ask in chat**, the #892 index-rebuild line) is gone with `SearchViewModel`, `GuideQueries` and `SearchQueries.search`/`messagesIndexRebuildPending`. The knowledge index, `search_knowledge` and the CLI stay; `SearchQueries.sanitizeFTS5Query` stays for Memory. Home's Knowledge search card opens AI Chat.

## Tests

`make test-swift FILTER='ConnectionsTabTests|HomeLinkTests|SidebarSectionTests|EmptyStateCopyCoverageTests|NotificationRouteTests'`; shots `connections-overview` and `connections-blocked` in `DesignShotCatalog`.
