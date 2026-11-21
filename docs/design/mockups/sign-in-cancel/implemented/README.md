# Cancel for a waiting browser sign-in — as built

The production views of #2132 with a sign-in held in the browser, in light and dark, to compare with the [mockups](../README.md). Each shot runs the place's real start against a stand-in: a stub `watchtower` that blocks until the shots end (Slack, Jira, Confluence, Quick Connections) or a held scripted CLI (the company models). The fixtures are `SignInWaitBuiltShots` in `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+SignInWaitBuilt.swift`; sample data only (`acme` / `example.com`).

| Shot | Place | Mockup |
|---|---|---|
| `sign-in-wait-built-row-slack` | S1: Connections → Slack, a workspace's **Re-login** | `sign-in-wait-row-waiting` |
| `sign-in-wait-built-row-jira` | A1: Connections → Jira, a site's **Re-login** | `sign-in-wait-row-waiting` |
| `sign-in-wait-built-row-quick` | Q1: Quick Connections, **Sign in again** | `sign-in-wait-row-waiting` |
| `sign-in-wait-built-row-narrow` | S1 at 420 pt | `sign-in-wait-row-narrow` |
| `sign-in-wait-built-section-confluence` | A2: **Grant Confluence access** | `sign-in-wait-section-waiting` |
| `sign-in-wait-built-section-own-google` | G5: **Use my own Google project** | `sign-in-wait-section-waiting` |
| `sign-in-wait-built-company-card` | C1: a company card whose chain waits, its sheet closed | `sign-in-wait-company-card-waiting` |
| `sign-in-wait-built-chat-card` | S2: an agent card's **Reconnect Slack** | `sign-in-wait-chat-card-waiting` |
| `sign-in-wait-built-wizard-check` | C2: the setup wizard's Google **Check by signing in** | `sign-in-wait-wizard-check-waiting` |

The Google places G1–G4 (account row, Connect Google Calendar, the Calendar banner and its top line) come with their own shots once they are built.

## What matches

Every place shows the spinner, the line and the hint from `SignInWaitCopy`, and a visible **Cancel**. A waiting row's dot is grey, never red. The place's own start button (Re-login, Sign in again, Grant Confluence access, Connect, Connect the rest) is gone or disabled while the sign-in waits.

## Differences from the mockups, and why

- **Slack row keeps its controls.** The Slack row shows **Cancel** after its **Enabled** switch and keeps **Rename…** and **Remove**, disabled; the mockup's waiting row shows only Cancel. Jira and Quick Connections hide the row's other controls, as the mockup does. The disabled controls are the connector's existing "busy" state, which the spec keeps.
- **Remove is blue on Slack and Jira.** The mockups now draw **Remove** red (`KitQuietButtonStyle(label: Tone.error)`), as Quick Connections does; the Slack and Jira rows still use the plain quiet style.
- **Slack at 420 pt.** Cancel stays visible, as the spec asks, but the row's trailing controls (dot, Enabled switch, Cancel, Rename…, Remove) leave the title column a few characters wide: the workspace name, its domain and the two waiting lines wrap almost word by word. The mockup row, with only Cancel in its trailing slot, wraps cleanly.
- **Chat card keeps Retry.** The failed send's card shows **Retry** under the waiting line; the mockup draws no Retry. Retry is the card's own action and was there before.
- **Confluence puts the line first.** The waiting line sits at the top of the section, above the consent text, so it stays when a reload switches the section's content; the mockup draws it under the explanation.
- **Own Google project and the wizard check are whole steps.** They show the step's guide and the dropped client file above the line, and **Connect** disabled; the mockups draw the line on its own.
- **Company card** shows **Connect the rest** disabled at the trailing edge, which the mockup leaves out.

Render them again with:

```sh
cd WatchtowerDesktop
DESKTOP_SHOTS_DIR=../build/sign-in-built swift test --filter DesignShotsTests.testSignInWaitBuiltShotsRender
```
