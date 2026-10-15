# Watchtower for iPhone — App Store listing draft

Board #173. Texts for App Store Connect (#178), the App Review notes (#182), the privacy policy's iPhone section (#177) and the App Privacy / Age Rating answers (#180). Limits are App Store Connect's; counts are in brackets.

## Listing (#178)

**Name** (≤ 30) — owner's choice, see the ask. Candidates: `Watchtower Companion` [20], `Watchtower Remote` [17], `Watchtower` [10] (likely taken).

**Subtitle** (≤ 30): `Your Mac's AI agents, in hand` [29]

**Category:** Productivity (primary), Developer Tools (secondary).

**Copyright:** `2026 <developer account name>` (the name on the Apple developer account).

**Promotional text** (≤ 170, editable without a new build):

> Answer your coding agents' questions, follow their sessions and record meetings for your Mac to transcribe — while you are away from the desk.

**Keywords** (≤ 100, comma-separated, no spaces): `claude,codex,agent,ai,assistant,workbench,companion,meeting,recorder,transcribe,kanban,board` [94]

**Description** (≤ 4000):

> Watchtower for iPhone is the companion to Watchtower for Mac. It puts the work your Mac runs in your pocket: the questions your AI agents are waiting on, the sessions they run, the boards they work, and the meetings you record.
>
> REQUIRES WATCHTOWER FOR MAC
> The iPhone app shows what your own Mac publishes. Install Watchtower on your Mac from aiwatchtowers.com, open Settings → Mobile → Use Watchtower on iPhone, and scan the code with this app. Without a Mac you can still look around: tap Try the Demo on the first screen.
>
> ANSWER YOUR AGENTS
> When Claude Code or Codex needs a decision, a check or a document review, the ask reaches your phone. Answer it with a tap or a note, and the session on your Mac continues.
>
> FOLLOW AND START SESSIONS
> See which sessions are working, waiting or finished, read their reports, send a line into a running session, or start a task from the board.
>
> YOUR BOARDS
> Browse each workbench's targets and their status, comment, and move work along.
>
> RECORD MEETINGS
> Record a meeting or a voice note on the phone. Recording starts and stops only when you tap; the audio goes to your Mac, which transcribes it and writes the recap.
>
> PRIVATE BY DESIGN
> There is no Watchtower server. The phone and your Mac talk through your own iCloud, end-to-end encrypted with keys only your devices hold. We collect nothing: no accounts, no analytics, no tracking.
>
> Several Macs? Link up to four and switch between them.

**Support URL:** `https://aiwatchtowers.com/support/` (to be added to the site) — or `https://aiwatchtowers.com/` with the contact address `info@aiwatchtowers.com`.
**Marketing URL:** `https://aiwatchtowers.com/`
**Privacy Policy URL:** `https://aiwatchtowers.com/privacy/`

## App Review notes (#182)

> Watchtower for iPhone is a companion to Watchtower for Mac, a desktop app distributed outside the Mac App Store (Developer ID, aiwatchtowers.com). The phone shows what the user's own Mac publishes through the user's own iCloud (CloudKit private database, end-to-end encrypted); there is no developer server and no account.
>
> TO REVIEW WITHOUT A MAC: on the first screen tap "Try the Demo". It opens two sample Macs with sample data and every screen of the app: Now, Workbench (boards, sessions, asks), Calendar and recording, Settings. Answers, comments and recordings in the demo stay on the device. "Exit Demo" in the top bar returns to the first screen.
>
> LINKING A REAL MAC: the Mac shows a QR code under Settings → Mobile; the phone scans it and both devices exchange keys through iCloud. A video of linking and live data: <link>.
>
> BACKGROUND MODES: "audio" keeps a recording the user started running while the phone is locked; recording starts and stops only by the user's tap and shows the system recording indicator. "remote-notification" lets silent CloudKit pushes refresh the data the Mac published.
>
> PERMISSIONS: the camera is used only to scan the Mac's QR code; the microphone only for recordings the user starts.

## Privacy policy — iPhone section (#177)

To add to `https://aiwatchtowers.com/privacy/` (repo `lending`, `public/privacy/index.html`), as a section after "Where your data lives":

> **Watchtower for iPhone**
>
> The iPhone app is a companion to Watchtower for Mac and follows the same rule: we collect nothing, and no server of ours is involved.
>
> - **iCloud, end to end encrypted.** The phone and your Mac exchange data through your own iCloud account (Apple's CloudKit, your private database). Every record is encrypted on the device with keys only your linked devices hold; Apple stores ciphertext, and we have no access to it.
> - **On the phone.** What your Mac publishes (asks, sessions, boards, calendar events, recaps) is kept in an encrypted local database on the phone. Unlinking a Mac or deleting the app removes it.
> - **Camera.** Used only to scan the code your Mac shows when you link the phone. No image is stored or sent.
> - **Microphone.** Used only for recordings you start and stop yourself. The audio is encrypted and sent through your iCloud to your Mac, which transcribes it; the phone deletes its copy once the Mac has it.
> - **No analytics or tracking.** The app has no analytics, crash-reporting or advertising SDKs and does not track you.
> - **No AI training.** Your data is never used to train AI or machine-learning models — by us or, through us, by anyone else.

Also add to "Contact us" a support line, and to "What we collect" a sentence pointing at this section.

## App Privacy (#180)

- **Data collection:** "No, we do not collect data from this app." Rationale: Apple's definition is data transmitted off the device in a way the developer or a third-party partner can access. The app sends data only to the user's own iCloud private database, end-to-end encrypted, and to the user's own Mac; no developer server, no SDK. Matches `PrivacyInfo.xcprivacy` (`NSPrivacyCollectedDataTypes` empty, `NSPrivacyTracking` false).
- **Age Rating:** every content question "None"; no web access (the app has no browser view), no user-generated content shared with other users, no gambling → 4+.
- **Price:** Free. Requires the Free Apps agreement (in place by default).
- **Availability:** owner's choice (see the ask); EU storefronts need the DSA trader declaration first (#181).
- **Export compliance:** already answered in `Info.plist` (`ITSAppUsesNonExemptEncryption` = false: only exempt encryption).

## Screenshots (#179)

6.9" (1320 × 2868), taken from the demo on the simulator with `make mobile-shots` (`ScreenshotTourTests`): Now, Workbench board, an ask answer, Calendar with a recording, a session report. Sample data only (`DemoSeed`).
