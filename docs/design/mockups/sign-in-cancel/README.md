# Cancel for a waiting browser sign-in

Proposal mockups for [the spec](../../../superpowers/specs/2026-11-21-sign-in-cancel-design.md) (#2132), in light and dark. They are drawn with the kit's `SignInWaitLine`, `SignInWaitText` and `SignInWaitCancel`, the real `CompanyAccountRow`, and synthetic data (`acme` / `example.com`). The fixtures are `SignInWaitShotFixtures` in `DesignShotCatalog`.

| Shot | State |
|---|---|
| `sign-in-wait-row-idle` | An account needs a sign-in: **Re-login**. The same state comes back after Cancel. |
| `sign-in-wait-row-waiting` | The sign-in waits: spinner and **Cancel** in the row; the other buttons of the connector are disabled. |
| `sign-in-wait-row-timed-out` | The CLI gave up after 5 minutes: its error, and **Re-login** as the Retry. |
| `sign-in-wait-row-narrow` | The waiting row at 420 pt: the text wraps and Cancel stays visible. |
| `sign-in-wait-section-waiting` | A section-level sign-in (Confluence access, Connect Google Calendar, own Google project). |
| `sign-in-wait-banner-waiting` | The Calendar health banner's Reconnect. |
| `sign-in-wait-calendar-top-waiting` | The revoked-calendar alert's legacy sign-in (no single account): the line at the top of Calendar; the empty state's Connect is disabled. |
| `sign-in-wait-company-card-waiting` | A company chain running after its sheet was closed. |
| `sign-in-wait-chat-card-waiting` | An agent card's **Reconnect Slack**. |
| `sign-in-wait-wizard-check-waiting` | The company setup wizard's sign-in check. |

Render them again with:

```sh
cd WatchtowerDesktop
DESKTOP_SHOTS_DIR=../build/sign-in-shots swift test --filter DesignShotsTests.testSignInWaitShotsRender
```
