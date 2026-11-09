# iPhone: changes that are not delivered

For a linked hub that supports ordered delivery, the iPhone shows changes that have not reached it on **Now**. A held change holds the ones after it. The current Mac app's iCloud hub does not enable ordered delivery, so these lists do not appear for that hub; see [iPhone](iphone.md).

## Why use it
<!-- learn: none -->

You answer an ask away from your desk. With ordered delivery, you can see whether that answer is still queued or needs another try.

## How it works
<!-- learn: none -->

Ordered delivery starts when the linked hub supports it. Until then, your phone keeps its existing delivery behavior.

### Over Relay
<!-- learn: none -->

Relay isn't in the current version of Watchtower for iPhone.

While the relay gives no answer, **Now** shows "Relay unavailable for 3 min. Your changes wait on this iPhone." above **Waiting to send**. The rows stay queued and go out in order when the relay is back, or over iCloud after **Switch Work Mac to iCloud**, which appears at 10 minutes.

When your subscription ends and the Mac moves to iCloud, changes the Mac had not confirmed go out again over iCloud. If the Mac stays on Relay because another subscribed phone uses it, they land under **Not delivered** with "Work Mac runs over Relay now". See [iPhone: Relay](iphone-relay.md).

When the phone is waiting for keys after the Mac's weekly key change, **Now** says the feed is parked rather than empty; your changes stay queued and nothing is lost. If your Mac moved on without this iPhone, a banner on **Now** and in **Settings → Macs** shows a date. Paying alone may not bring the phone back; opening the Mac app may not either. After that date, when you open the app and Relay still refuses this iPhone a second time, the link ends: its history on this iPhone and unsent changes go, and you link the Mac again. If this iPhone pays while its Mac moved to iCloud, the Mac's row stays until you press **Forget This Mac**. If the phone cannot read the Mac's move at all, it shows no banner and keeps a stale row; use **Forget This Mac** in **Settings → Macs**.

## Using it
<!-- learn: none -->

### Read Waiting to send and Not delivered
<!-- learn
id: iphone-not-delivered
title: See what did not reach your Mac
text: With an ordered-delivery hub, open **Not delivered** on **Now** and press **Retry** to send a change again.
area: iphone
level: next
kind: feature
since: 0.26.4
-->

- **Waiting to send** lists the oldest changes still queued, each with the time you made it, with a count and "2 more" past the first three. It shows while the phone is holding changes back, and they go out in order as soon as the Mac can take them.
- **Not delivered · 2** appears when a change never reached the Mac: iCloud refused to carry it for good, or the Mac gave no answer for 24 hours ("No answer from Work Mac for 24 hours"). Tap it to open the list, oldest first.

### Retry or dismiss
<!-- learn: none -->
Each row in the **Not delivered** list has **Retry**, which sends that change again, after anything you did since. While it runs the button is off. If it fails, the reason shows under that row: "Unlock your iPhone to retry." or "Couldn't retry. Try again."

**Dismiss All** drops every listed change for good, after you confirm ("Dismiss 2 actions? They won't be sent."). If that fails, the phone says "Couldn't dismiss. Try again."

## When it's empty or wrong
<!-- learn: none -->

- **No delivery lists on Now.** Your hub does not enable ordered delivery, or there are no queued or undelivered changes.
- **Unlock your iPhone to retry.** Unlock the phone, then press **Retry** again.

## Related
<!-- learn: none -->

- [iPhone](iphone.md)
- [iPhone: permission prompts and interrupts](iphone-agent-prompts.md)

For developers: [docs/features/mobile-companion.md](../../features/mobile-companion.md)
