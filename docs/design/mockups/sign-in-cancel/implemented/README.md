# Cancel for a waiting browser sign-in — as built

The production views of #2132 with a sign-in held in the browser, in light and dark, to compare with the [mockups](../README.md). Each shot runs the place's real start against a stand-in: a stub `watchtower` that blocks until the shots end (Slack, Jira, Confluence, Quick Connections), a login environment held on a gate so the CLI never launches (Google), or a held scripted CLI (the company models). The fixtures are `SignInWaitBuiltShots` in `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+SignInWaitBuilt.swift`; sample data only (`acme` / `example.com`).

| Shot | Place | Mockup |
|---|---|---|
| `sign-in-wait-built-row-google` | G1: Connections → Google, an account's **Re-login** | `sign-in-wait-row-waiting` |
| `sign-in-wait-built-row-slack` | S1: Connections → Slack, a workspace's **Re-login** | `sign-in-wait-row-waiting` |
| `sign-in-wait-built-row-jira` | A1: Connections → Jira, a site's **Re-login** | `sign-in-wait-row-waiting` |
| `sign-in-wait-built-row-quick` | Q1: Quick Connections, **Sign in again** | `sign-in-wait-row-waiting` |
| `sign-in-wait-built-row-narrow` | S1 at 420 pt | `sign-in-wait-row-narrow` |
| `sign-in-wait-built-section-connect-calendar` | G2: **Connect Google Calendar** | `sign-in-wait-section-waiting` |
| `sign-in-wait-built-section-confluence` | A2: **Grant Confluence access** | `sign-in-wait-section-waiting` |
| `sign-in-wait-built-section-own-google` | G5: **Use my own Google project** | `sign-in-wait-section-waiting` |
| `sign-in-wait-built-company-card` | C1: a company card whose chain waits, its sheet closed | `sign-in-wait-company-card-waiting` |
| `sign-in-wait-built-chat-card` | S2: an agent card's **Reconnect Slack** | `sign-in-wait-chat-card-waiting` |
| `sign-in-wait-built-wizard-check` | C2: the setup wizard's Google **Check by signing in** | `sign-in-wait-wizard-check-waiting` |
| `sign-in-wait-built-calendar-top` | G4: the revoked-calendar alert's legacy sign-in, at Calendar's top | `sign-in-wait-calendar-top-waiting` |

G3, the Calendar health banner's **Reconnect** (mockup `sign-in-wait-banner-waiting`), has no shot: the banner shows only when Calendar is connected and its sync health says the account failed, and `CalendarEventsView` reads both from the live Google auth service and the daemon into private state, which a shot cannot set. `GoogleSignInWaitViewTests.testCalendarSignInWaitSpot` covers where its line goes.

## What matches

Every place shows the spinner, the line and the hint from `SignInWaitCopy`, and a visible **Cancel**. A waiting row's dot is grey, never red. A waiting row (Google, Slack, Jira, Quick Connections) shows only the spinner and Cancel in its trailing slot, as the mockup does; the place's own start button (Re-login, Sign in again, Grant Confluence access, Connect, Connect the rest) is gone or disabled while the sign-in waits. **Remove** is red on the Slack, Jira, Google and Quick Connections rows, as in the mockups. The chat card shows neither Retry nor the orange retry note while its sign-in waits; both come back when the wait ends.

## Differences from the mockups, and why

- **The other row at 420 pt.** The waiting Slack row reads normally at 420 pt. The idle row above it keeps its Enabled switch, Reconnect, Rename… and Remove, which leave its domain line a few characters wide (`acme.s lack.-com`); that is the row's idle layout, not the waiting state, and the mockup draws no idle row at this width.
- **Confluence puts the line first.** The waiting line sits at the top of the section, above the consent text, so it stays when a reload switches the section's content; the mockup draws it under the explanation.
- **Own Google project and the wizard check are whole steps.** They show the step's guide and the dropped client file above the line, and **Connect** disabled; the mockups draw the line on its own.
- **Company card** shows **Connect the rest** disabled at the trailing edge, which the mockup leaves out.
- **Chat card** keeps the red failure line and the card's header and body above the waiting line, as the mockup's card does in outline; the mockup's short "Slack needs a new sign-in" stands in for the real failure text.
- **Controls outside #2132 stay enabled.** During a row's wait, Slack's legacy Workspace **Reconnect Slack** and the Jira and Google **Paste a company code** stay enabled; none is a place this change covers.
- **Google section and row.** Connect Google Calendar waits under the add section's buttons, which stay greyed out; the mockup's section draws the line on its own. The Google detail also shows its Calendar and Gmail settings below.
- **Calendar's top line** sits above Calendar's empty state ("No meetings yet") with its **Connect Google Calendar** disabled; the mockup draws it above a day with no events.
- **The Confluence shot's last line** ("Confluence access not granted — run: …") is the fixture runner's consent error, shown as the section's consent message.
- **The Jira shot is cropped** to the sites and Add an account: the sections below read the live CLI, which the shots' test process does not have.

Render them again with:

```sh
cd WatchtowerDesktop
DESKTOP_SHOTS_DIR=../build/sign-in-built swift test --filter DesignShotsTests.testSignInWaitBuiltShotsRender
```
