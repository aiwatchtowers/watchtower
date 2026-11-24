# iPhone

The Watchtower iPhone app is a window onto your tower: your Mac or server running Watchtower. It shows what waits for you, lets you act on it, and records meetings away from your desk.

## Why use it

You step away while a Workbench session waits on a question. The phone shows an orange card; a few taps answer it and the session goes on. **Record** sends a meeting's audio to your Mac for the transcript and recap.

## How it works

The Mac is the **hub**. With **Mobile sync** on, it puts asks, Workbench boards and sessions, calendar and recaps into your iCloud. The phone reads them and sends requests back; the Mac applies them when awake. Hubs with ordered delivery apply changes in order; see [not delivered](iphone-not-delivered.md).

Everything is sealed with keys exchanged at linking; iCloud holds only ciphertext. The phone never gets terminal output or a raw transcript; a session's chat is the exception (below).

An ask answered on the phone waits as **Waiting for your tower** while it sleeps. A Mac checks for requests every 30 seconds and writes a heartbeat every 15 minutes.

A phone links up to four towers and switches between them; each has its own data.

### What the Mac shows about each phone

Settings → **Mobile** on the Mac lists each phone with how it syncs and who switched it last. A phone's row adds a line when something needs you. **Diagnostics** shows how fast the Mac handles phone actions; the timings stay on the Mac.

### Which builds pair

iCloud keeps a Development and a Production environment; records saved in one never reach the other. The downloaded (Developer ID) Mac app and a TestFlight or App Store phone build are both Production and pair.

A phone run from Xcode is Development and pairs only with a Development Mac. A mixed pair fails silently.

A Mac build without iCloud signing shows **Needs a signed build** and can't use iCloud. An unsigned phone build is a demo.

### Relay
<!-- learn: none -->

Relay isn't in the current version of Watchtower for iPhone. See [iPhone: Relay](iphone-relay.md).

## Using it

### Link a phone
<!-- learn
id: iphone-link
title: Link your iPhone
text: Turn on **Mobile sync** in **Settings → Mobile**, press **Link a phone…** and scan the code.
area: iphone
level: basics
kind: feature
since: 0.24.0
action: hotkey:settings
done_when: iphone.paired
-->

1. On the Mac, open Settings → **Mobile** and turn on **Mobile sync**. It applies at once.
2. Under **Phones**, press **Link a phone…**. A QR code appears for 10 minutes. **New code** makes another.
3. On the iPhone, tap **Scan the code on your tower** (or scan with the Camera app) and point it at the code.
4. The phone shows a four-digit code. Check it matches the code on the Mac, then click **Link** there (**Refuse** cancels).
5. The phone shows **Linked to <Mac name>**. **Continue** asks for notification permission and opens **Now**.

On the Mac's Apple ID, the phone syncs through your private iCloud. With another Apple ID, it joins the two folders the Mac shares. Failed phone recordings wait under **Recordings** (**Retry**, **Discard…**).

### Use the tabs
<!-- learn
id: iphone-answer-asks
title: Answer asks from your phone
text: A session's question shows under **Waiting for you** on the phone's **Now**; answer it and the session goes on.
area: iphone
level: basics
kind: feature
since: 0.24.0
-->
<!-- learn
id: iphone-record
title: Record a meeting on your iPhone
text: Tap **Record** in the phone's **Calendar**; your Mac transcribes the audio and writes the recap.
area: iphone
level: next
kind: feature
since: 0.24.0
-->

- **Now** shows your tower's status, then **Waiting for you**, **Working**, **Ended** and the next meeting (see [Now and sessions](iphone-workbench.md#now-and-sessions)). The gear opens Settings.
- **Inbox** is the Mac's Inbox; the orange badge counts what waits on you. Swipe a row for **Done**, **Snooze** or **Hide**, or hold it. See [Inbox](inbox.md).
- **Workbench** lists your workbenches as cards. Open one for **Sessions** (split like Now) or **Board** (targets with status, priority and comments). A group's done sub-targets hide behind **Show done (N)** (remembered).
- **Chats** holds your AI chats; without Relay it says why it can't chat ([iPhone: AI chat](iphone-chat.md)).
- **Calendar** shows your tower's events with prep and **Record**, kept 30 minutes past an unrecorded event's end. **Recordings** has **Record a voice note**.

Asks come in three kinds: a question, a review (hold a paragraph to comment; **Request changes** needs a comment or a note) and a check (**Works**, **Doesn't work** or **Didn't check** per step).

### Read a session's chat
A session opens as its chat, with a field to write to it and its report behind **⋯**. Tool output is never shown. See [iPhone: the workchat](iphone-workbench.md).

### Let the phone do more
<!-- learn
id: iphone-start-session-any-task
title: Start sessions from your phone
text: Allow **Start sessions from this phone**, then start one from a target or with **No target** and a typed task.
changed: A session can start with no target: type the task on the phone.
replaces: [iphone-start-sessions]
area: iphone
level: power
kind: feature
since: 0.26.2
-->
<!-- learn
id: iphone-type-into-sessions
title: Type into a session from the phone
text: Turn on **Type into sessions from this phone** and **Allow…** it on the Mac to send a session a line.
area: iphone
level: power
kind: feature
since: 0.24.0
-->

Three switches under Settings → **Workbench** on the phone:

- **Start sessions from this phone** lets you start a session from a target, or from the Workbench's **New session** with **No target** and a task you type. It runs the Mac's default agent. The Mac decides: allow typing on its phone row, then **Allow…** on **Starting sessions off**. Until then **Start session** stays off and says why.
- **Type into sessions from this phone** lets you send a line to a running session. The Mac must also approve: the phone row on the Mac shows **Asks to type into sessions**, and **Allow…** grants it. **Revoke** takes it back.
- **Answer permission prompts from this phone** answers permission prompts (off by default: approvals wait at the Mac). The Mac's row shows **Asks to answer permission prompts**, with its own **Allow…**.

Without the typing switch, a running session's bottom bar says so, with **Turn On**. A server tower has no Settings window: the phone shows the `watchtower hub allow` command to run there.

### Start a target's session
<!-- learn
id: iphone-start-from-target
title: Start a target's session in two taps
text: Pick a target on the phone's board and press **Start session**; its brief is ready, nothing to type.
area: iphone
level: next
kind: tip
since: 0.28.3
-->

From a target, the sheet shows its intent and a ready brief: press **Start session**. Editing the brief needs typing allowed.

### Read your timings
<!-- learn: none -->

Settings → **Diagnostics** shows "Action → result on screen · 7 days": your action count, how long results took (p50, p90) and the "Tower's answer" part, measured on this iPhone, sent nowhere. "Timings need an updated Watchtower on your tower." means no tower can be timed yet. **Battery** is here too.

### Link another tower, or unlink
<!-- learn
id: iphone-more-macs
title: Link up to four towers
text: In the phone's Settings → **Towers**, press **Add tower** and scan another code, then switch between them.
area: iphone
level: power
kind: feature
since: 0.24.0
-->
<!-- learn
id: iphone-tower-switcher
title: Switch towers from the status chip
text: With several towers linked, tap the status chip atop **Now** to see them all and switch every tab.
area: iphone
level: next
kind: tip
since: 0.28.3
-->

Settings → **Towers** lists your towers. **Add tower** scans another code (up to four); drag rows to reorder. **Unlink** (or **Forget**, for one that removed the phone or is long offline) deletes its data from the phone and says how many unsent changes it lost. With several, the status chip atop Now, Workbench and Calendar (**Acme Mac · online ▾**) lists them and the questions waiting on the others; a tap switches every tab.

On the Mac, **Remove…** next to a phone unlinks it. On the phone, that Mac's hub freezes in both cases: what it synced stays readable, nothing new arrives, until you tap **Forget**. A phone on another Apple ID also leaves the Mac's iCloud sharing.

## When it's empty or wrong

- **The tower doesn't show up on the phone.** Check that Watchtower is open, **Mobile sync** is on, the Mac is awake, the build is signed and iCloud is on; then the pairing above.
- **"This code expired" or "This code can't be used".** Press **New code** on the Mac and scan again. A code works for one phone. If it also says "This iPhone is already linked to <tower>", just close the screen.
- **"Sign in to iCloud on this iPhone to use Watchtower".** The phone and the Mac both need an iCloud account ("Mobile isn't available on this Mac: iCloud is off.").
- **Another Apple ID won't link.** "This tower can't share with another Apple ID right now" means the Mac's share failed. Show a new code.
- **"<tower> hasn't synced for a day".** No heartbeat for a day. If the Mac changed iCloud account, link again.
- **"<tower> removed this phone".** Its data stays readable, nothing new arrives; **Forget** deletes it and clears the row.
- **"Your Mac has not allowed this phone to start sessions"** under **Start session**. Allow it on the Mac as above (a server tower names its `watchtower hub allow` commands).
- **"<hub> works over Relay only".** Relay isn't in the current version of Watchtower for iPhone. That hub (a Linux box or a Mac without the Watchtower app) links only over Relay. Link it from its Mac app, if it has one.
- **Nothing updates.** Mobile stops when you quit Watchtower, not when you close its window.

Not syncing? See [The iPhone is not syncing](../troubleshooting/iphone-not-syncing.md).

## Related

- [iPhone: permission prompts and interrupts](iphone-agent-prompts.md)
- [iPhone: work alerts](iphone-alerts.md)
- [Menu bar and updates](menu-bar-and-updates.md) keeps the Mac side running.

For developers: [docs/features/mobile-companion.md](../../features/mobile-companion.md)
