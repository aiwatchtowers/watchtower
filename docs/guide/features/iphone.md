# iPhone

The Watchtower iPhone app is a window onto your Mac. It shows what is waiting for you, lets you answer asks, edit the Workbench board and start sessions, and records meetings you attend away from your desk. It works through your own iCloud, so nothing goes through a Watchtower server.

## Why use it

You step away from your desk while a Workbench session waits on a question. The phone shows an orange card for the ask, you answer it in a few taps, and the session carries on. The same app lists today's meetings with their prep, and its red **Record** button sends the audio to your Mac, which transcribes it and writes the recap.

## How it works

The Mac is the **hub**. With **Sync with iPhone** on, it publishes a slice of your data (asks, Workbench boards and sessions, calendar, recaps) into your iCloud. The phone reads that slice and sends its changes back as requests, which the Mac applies when it is awake.

Everything is sealed with keys exchanged when you link, so iCloud only holds ciphertext. The phone never gets a session's transcript or terminal output.

Because the Mac does the work, the phone depends on it. An ask answered on the phone waits as **Waiting for your Mac** while the Mac sleeps, and applies on wake. The Mac checks for phone requests every 30 seconds, or every 3 seconds for five minutes after the last one, and writes a heartbeat every 15 minutes.

A phone links to up to four Macs and switches between them; each Mac is its own hub with its own data.

### Which builds pair

iCloud keeps a Development and a Production environment, and records saved in one never reach the other. A normal Mac build and a TestFlight or App Store phone build are both Production and pair. A phone run from Xcode is Development, and only pairs with a Mac built for Development. Mixed pairs fail silently: the phone never sees the Mac.

A Mac build without iCloud signing shows **Needs a signed build** and cannot turn sync on. An unsigned phone build runs a demo linked to "Acme Mac".

## Using it

### Link a phone

1. On the Mac, open Settings → **Mobile** and turn on **Sync with iPhone**. It applies at once.
2. Under **Phones**, press **Use Watchtower on iPhone**. A QR code appears for 10 minutes. **New code** makes another.
3. On the iPhone, tap **Scan the code on your Mac** (or scan with the Camera app) and point it at the code.
4. The phone shows a four-digit code. Check it matches the code on the Mac, then click **Link** there (**Refuse** cancels).
5. The phone shows **Linked to <Mac name>**. **Continue** asks for notification permission and opens **Now**.

If the phone uses the same Apple ID as the Mac, it syncs through your private iCloud. With another Apple ID, it joins the two folders the Mac shares; the phone row says **Same Apple ID** or **Shared**.

### Use the three tabs

- **Now** shows whether your Mac is online ("Mac online · 12s"), everything **Waiting for you** across workbenches, and session counts. The gear opens Settings.
- **Workbench** lists your workbenches as cards. Open one for **Sessions** (asks, reports, a stop button) or **Board** (targets with status, priority and comments). Its badge counts open asks.
- **Calendar** shows the events your Mac publishes, with prep, the **Record** button and the **Recordings** list.

Asks come in three kinds: a question, a review (select text, **Comment on the selection**, then **Approve** or **Request changes**) and a check (mark each step **OK**, **Broken** or **Skipped**).

### Let the phone do more

Two switches under Settings → **Workbench** on the phone:

- **Start sessions from this phone** lets you start a session from a target. It runs the Mac's default agent.
- **Type into sessions from this phone** lets you send a line to a running session. The Mac must also approve: the phone row on the Mac shows **Asks to type into sessions**, and **Allow…** grants it. **Revoke** takes it back.

A permission prompt in a session is never answered from the phone; the session shows **Needs approval on the Mac**.

### Link another Mac, or unlink

Settings → **Macs** lists your Macs. **Add Mac** scans another code (up to four), and rows can be dragged to reorder. **Unlink** (or **Forget**, for a Mac that removed the phone or is long offline) deletes that Mac's data from the phone; changes not yet sent are lost, and the phone says how many ("Not sent: 3 items were still waiting for your Mac").

On the Mac, **Remove…** next to a phone unlinks it. A phone on another Apple ID loses the Mac's data at once. A phone on your own Apple ID keeps what it already synced but reads nothing new.

## When it's empty or wrong

- **The Mac doesn't show up on the phone.** Check that Watchtower is open on the Mac, **Sync with iPhone** is on, the Mac is awake, the build is signed, and iCloud is on. If it still does not appear, check the environment pairing above.
- **"This code expired" or "This code can't be used".** Press **New code** on the Mac and scan again. A code works for one phone.
- **"Sign in to iCloud on this iPhone to use Watchtower".** The phone needs an iCloud account; the Mac needs one too ("Mobile isn't available on this Mac: iCloud is off.").
- **Another Apple ID won't link.** The message "This Mac can't share with another Apple ID right now" means the Mac's share failed. Show a new code and try again.
- **"<Mac> hasn't synced for a day".** The phone has had no heartbeat for a day. If the Mac changed iCloud account, link again.
- **"<Mac> removed this phone".** The Mac removed the link. The phone drops that Mac's data; **Forget** clears the row.
- **"iCloud is slowing sync down"** on the Mac's Mobile tab means iCloud has held sync back for over a minute. It clears on its own.
- **Nothing updates.** The hub runs inside the Watchtower app, so it stops when you quit Watchtower. Closing the window is fine; the app keeps running in the menu bar.

## Related

- [Menu bar and updates](menu-bar-and-updates.md) for keeping the Mac side awake and running.

For developers: docs/features/mobile-companion.md
