# Company code from the Slack app — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A colleague without the company code finds it on their own: Watchtower asks for their Slack address and opens the workspace's app list with three steps to the code, and the About text on the app's Slack page reads as instructions.

**Architecture:** Go: `company.AboutText` is rewritten to a sectioned layout with an honest cut order; `aboutLeadsWithCode` goes. Desktop: a pure `SlackAddress` parser in `WatchtowerCore`, strings in `CompanyConnectionsPresentation`, a transient `slackAddress` on `CompaniesZoneModel`, and a "No code? Find it in Slack" block under `CompaniesZone.codeField` that opens the app list through `@Environment(\.openURL)`.

**Tech Stack:** Go 1.26 (`internal/company`), SwiftUI + DesignKit (`WatchtowerDesktop`), XCTest.

**Spec:** `docs/superpowers/specs/2026-11-24-company-code-from-slack-app-design.md`

## Global Constraints

- Local-first: no bot, no server, no fetch. Watchtower only opens `https://<sub>.slack.com/apps/manage` in the browser.
- The Slack address is never stored (not in UserDefaults, not on disk, not in the DB): a plain in-memory property.
- UI strings in English, all in `CompanyConnectionsPresentation`; the design-shot mock copy (`Tests/DesignShots/CompanySetupMockCopy.swift`) mirrors every string the shots show.
- Accepted address forms: `acme`, `acme.slack.com`, `https://acme.slack.com/…`, `http://…`, any case, surrounding spaces, trailing slash, any path. `<sub>` is one label of `[a-z0-9-]`. `<sub>.enterprise.slack.com` is refused with its own caption.
- About text plain, under `slackmanifest.MaxLongDescription` (4000) together with the disclosures; the leading way in (the link) is never cut.
- Public repo: samples are `Acme`, `acme.slack.com`, `example.com` only.
- Inner loop only per task (`go test ./internal/company`, `make test-swift FILTER=…`, `make lint-diff`); the full gate once before the PR.

## Review Focus

- A pasted full app-page URL (`https://acme.slack.com/marketplace/A0…-watchtower`) or the `app.slack.com/...` redirect target: the first is accepted as `acme`; `app.slack.com` is refused with the generic caption (it is not a workspace) — pinned in Task 2's tests.
- Unicode/IDN or an underscore in the subdomain (`acmé`, `ac_me`): refused, not crashed — Task 2.
- The code field opened with a `codeError` shown at the same time as an invalid address caption: both captions render, each under its own field — Task 3's shot `codeField-slackInvalid` has a code error off; the `codePaste` shot keeps the code error with an empty address.
- A bundle exactly at the size where the install step must go: steps renumber 1–2 with no gap — Task 1.
- A company name with a newline or long text does not break the section layout: `AboutText` is given the name as stored; Task 1 tests a 200-character name still fits a typical bundle.

---

### Task 1: About text layout (Go)

> **Updated 2026-11-25 (owner, D9 in the spec):** download is a paragraph after the code, not step 1; cut order download → code; exact text in the spec. Task 2: `slackHintTitle` is the D9 heading; `codeInvalid` per the spec.

Depends on: none.

**Files:**
- Modify: `internal/company/about.go`
- Test: `internal/company/about_test.go` (replace the three `TestAboutText_*` tests)

**Interfaces:**
- Produces: `func AboutText(company, link, code string) string` — same signature, caller `cmd/company_publish.go:314` unchanged.

Exact texts (`<release>` = `slackapp.ReleasePage`):

Full:
```
Watchtower for <company>

How to connect
1. Install Watchtower: <release>
2. Open Watchtower.
3. Click this link: <link>
   If it does not open, paste the code below in Watchtower → Connections → Company code.

Company code
<code>
```
Install step cut: the same without the install line, steps `1. Open Watchtower.` / `2. Click this link: …`.
Code cut (also install cut): `Watchtower for <company>\n\nHow to connect\n1. Open Watchtower.\n2. Click this link: <link>` — no fallback line, no **Company code** section.
Try in that order; return the first for which `slackmanifest.Description(text)` succeeds; return the last candidate otherwise. Build the steps from a slice and number them in a loop.

- [ ] **Step 1: Write the failing tests**
  - `TestAboutText_FullLayout`: `AboutText("Acme", ConnectLink("eyJ2IjoxfQ"), "eyJ2IjoxfQ")` equals the full text above exactly.
  - `TestAboutText_CutsInstallStepFirst`: scan `n` from 1000 to 3000 step 10 with `wire := strings.Repeat("A", n)`; some `n` yields a text that contains `"Company code\n"+wire` and `"1. Open Watchtower.\n2. Click this link: "+link` and no `"Install Watchtower"`; no text ever contains `"Install Watchtower"` without `"Company code\n"`.
  - `TestAboutText_LargeBundleKeepsTheLinkOnly`: `wire := strings.Repeat("A", 3000)`; result equals the code-cut text exactly; `slackmanifest.Description(result)` has no error.
  - `TestAboutText_LinkNeverCut`: for `n` in 1000..3000 step 10 the result always contains `"Click this link: "+ConnectLink(wire)`, and for `n <= 2900` `Description` has no error.
  - `TestAboutText_LongCompanyName`: a 200-rune name with the `eyJ2IjoxfQ` bundle gives the full layout.
- [ ] **Step 2:** `go test ./internal/company -run TestAboutText` → FAIL.
- [ ] **Step 3:** Rewrite `AboutText`, delete `aboutLeadsWithCode` and its comment; update the doc comment to the new layout and cut order.
- [ ] **Step 4:** `go test ./internal/company` → PASS; `make lint-diff` clean.
- [ ] **Step 5:** Commit `feat(company): About text as how-to-connect steps, link then code`.

### Task 2: SlackAddress parser + strings (WatchtowerCore)

Depends on: none.

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Company/SlackAddress.swift`
- Create: `WatchtowerDesktop/Tests/Core/SlackAddressTests.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Company/CompanyConnectionsPresentation.swift` (near line 320)
- Modify: `WatchtowerDesktop/Tests/Core/CompanyConnectionsPresentationTests.swift` (lines ~132, ~469)
- Modify: `WatchtowerDesktop/Tests/DesignShots/CompanySetupMockCopy.swift` (line ~339)

**Interfaces:**
- Produces:
  ```swift
  package enum SlackAddress: Equatable {
      case empty
      case workspace(String)   // the subdomain, lowercased, e.g. "acme"
      case organization        // <sub>.enterprise.slack.com
      case invalid
      package static func parse(_ input: String) -> SlackAddress
      package static func appsURL(workspace: String) -> URL   // https://<sub>.slack.com/apps/manage
  }
  ```
  (The spec's `normalize` is `parse` returning `.workspace`; one entry point keeps the Grid caption decidable.)
- Produces in `CompanyConnectionsPresentation` (`package static let`):
  - `slackHintTitle = "No code? Find it in Slack"`
  - `slackAddressPlaceholder = "acme.slack.com"`
  - `openSlackApps = "Open Slack apps"`
  - `slackHintSteps = ["Search for Watchtower in the list and open it.", "Open App Details.", "Click the connect link, or copy the code and paste it above."]` (rendered numbered `1.`–`3.`)
  - `slackHintFallback = "Not in the list, or Slack asks you to sign in? Sign in to Slack in this browser and try again. Still nothing — ask your Slack admin for the Watchtower company code."`
  - `slackAddressInvalid = "Enter your Slack address, like acme.slack.com"`
  - `slackAddressOrganization = "That is your organization's address. Enter your workspace's, like acme.slack.com — it is in Slack's workspace menu."`
  - `static func slackAddressCaption(_ address: SlackAddress) -> String?` — `.invalid` → `slackAddressInvalid`, `.organization` → `slackAddressOrganization`, else nil.
  - `codeInvalid` becomes `"That is not a Watchtower company code. Copy it again from your company's Watchtower app page in Slack — see “No code? Find it in Slack” below."`

- [ ] **Step 1: Write the failing tests** (`SlackAddressTests`):
  - `.workspace("acme")` for: `"acme"`, `"acme.slack.com"`, `"ACME.Slack.com"`, `"  acme.slack.com  "`, `"https://acme.slack.com"`, `"https://acme.slack.com/"`, `"https://acme.slack.com/marketplace/A0X-watchtower"`, `"http://acme.slack.com/apps"`, `"acme-eu"` → `.workspace("acme-eu")`.
  - `.empty` for `""` and `"   "`.
  - `.organization` for `"acme.enterprise.slack.com"` and `"https://acme.enterprise.slack.com/"`.
  - `.invalid` for `"slack.com"`, `"app.slack.com"`, `"acme.example.com"`, `"ac me"`, `"ac_me"`, `"acmé"`, `"a.b.slack.com"`, `"https://"`.
  - `appsURL(workspace: "acme").absoluteString == "https://acme.slack.com/apps/manage"`.
  - Presentation: `slackAddressCaption(.invalid)`, `(.organization)` give the strings above; `(.empty)` and `(.workspace("acme"))` nil; `codeInvalid` equals the new text; update the old `codeInvalid` assertion (line ~469) and the mock copy.
- [ ] **Step 2:** `make test-swift FILTER='SlackAddressTests|CompanyConnectionsPresentationTests'` → FAIL.
- [ ] **Step 3:** Implement. `app` is not a workspace subdomain (refuse it explicitly). Strip scheme, path, query, trailing dot; lowercase; then match host = `<label>` or `<label>.slack.com` or `<label>.enterprise.slack.com`, label `^[a-z0-9-]+$`.
- [ ] **Step 4:** Same filter, plus `CompanyConnectFlowModelTests|CompaniesZoneModelTests|CompanySetupMockCopyTests` → PASS; `make lint-diff` clean.
- [ ] **Step 5:** Commit `feat(desktop): SlackAddress parser and the No code? copy`.

### Task 3: "No code? Find it in Slack" block + design shots

Depends on: Task 2.

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Company/CompaniesZoneModel.swift` (add `package var slackAddress = ""`, not persisted; `preview(code:codeError:slackAddress:)` gains the parameter with default `""`)
- Modify: `WatchtowerDesktop/Sources/Views/Connections/CompaniesZone.swift` (`codeField`, lines 168–189)
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+CompanySetup.swift` (`Overview` gains `slackValid`, `slackInvalid`), `DesignShotFixtures+CompaniesZone.swift` (frames seed `slackAddress: "acme.slack.com"` / `"acme.example.com"`, zone as `.companies`, code field open), `CompanySetupMockCopy.swift` (new strings)
- Test: `WatchtowerDesktop/Tests/Core/CompaniesZoneModelTests.swift`

**Interfaces:**
- Consumes: `SlackAddress.parse`, `SlackAddress.appsURL(workspace:)`, the Task 2 strings.

- [ ] **Step 1: Failing test** `CompaniesZoneModelTests.testSlackAddressIsNotPersisted`: set `slackAddress = "acme"` on one model; a fresh `CompaniesZoneModel { nil }` has `slackAddress == ""`, and `UserDefaults.standard.dictionaryRepresentation()` holds no value equal to `"acme"`.
- [ ] **Step 2:** `make test-swift FILTER=CompaniesZoneModelTests` → FAIL (no property).
- [ ] **Step 3:** Add the property; in `CompaniesZone` add `@Environment(\.openURL) private var openURL` and a `slackHint` view placed at the end of `codeField`'s VStack: title at `.caption` secondary; `HStack` of `TextField(Pres.slackAddressPlaceholder, text: $model.slackAddress).textFieldStyle(.kit)` and `Button(Pres.openSlackApps)` `.kitSecondary`, disabled unless `parse` is `.workspace`, action `openURL(SlackAddress.appsURL(workspace:))`; field `onSubmit` does the same when valid; caption from `slackAddressCaption` in `Tone.error`; steps numbered from `slackHintSteps`; fallback line `.caption` secondary; every multi-line `Text` with `.fixedSize(horizontal: false, vertical: true)`. Wrap the field row in `ViewThatFits` like `zoneButtons` so the narrow pane stacks it.
- [ ] **Step 4:** `make test-swift FILTER='CompaniesZoneModelTests|CompanySetupMockCopyTests'` → PASS; `make desktop-shots DESKTOP_SHOTS=<scratch>` renders `company-overview-codePaste`, `-slackValid`, `-slackInvalid` (and `-companies-narrow`); look at them; `make lint-diff` clean.
- [ ] **Step 5:** Commit `feat(desktop): No code? Find it in Slack under the company code field`.

### Task 4: Docs

Depends on: Tasks 1–3 (texts final).

**Files:**
- Modify: `docs/guide/start/company-setup.md` — under "Connect with your company's link or code" add "### No code? Find it in Slack" (enter the workspace address, **Open Slack apps**, the three steps, the fallback); in "Set up for my company" step 5/6 say the link and the code are on the app's page in the workspace's app list, so neither needs posting in a channel; step 1 of "Connect" says "click the link on your company's Watchtower app page in Slack (App Details)".
- Modify: `docs/features/company-setup.md` — S1.2 resolved (About layout, link leads pending the test publish), the No code? block, bot user ruled out (spec finding 2); `docs/features/README.md` summary line updated to match.

- [ ] **Step 1:** Edit per `docs/guide/WRITING.md`.
- [ ] **Step 2:** `grep -n "aboutLeadsWithCode\|Connect code:" docs internal -r` → no stale mention outside history.
- [ ] **Step 3:** Commit `docs: find the company code in Slack; About layout`.

### Task 5: Acceptance check on a test publish (owner)

Depends on: Tasks 1–4, gate green.

- [ ] Ask the owner (one `ask_owner` check): run **Publish** (or `watchtower slack app link`) from the branch build against the company app; on the app's Marketplace page confirm (a) the link is clickable and opens Watchtower, (b) the code copies whole, (c) the layout reads as sections. If (a) fails: a follow-up task puts the **Company code** section above the steps and step 3 becomes "Paste the code below in Watchtower → Connections → Company code." with the link as an "Or open this link…" line after it (spec D8), tests updated in `about_test.go`.
