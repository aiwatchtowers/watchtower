# iPhone: changes that are not delivered

When your Mac does not take a change you made on the iPhone, the phone shows it on **Now** instead of losing it quietly. The Mac applies a phone's changes in the order they were made, so a held change holds the ones after it. For anyone who already linked a phone (see [iPhone](iphone.md)).

## Using it

### Read Waiting to send and Not delivered
<!-- learn
id: iphone-not-delivered
title: See what did not reach your Mac
text: If a phone change does not reach the Mac, **Now** shows **Not delivered**; press **Retry** to send it again.
area: iphone
level: next
kind: feature
since: next
-->

- **Waiting to send** lists the oldest changes still queued, each with the time you made it, with a count and "2 more" past the first three. It shows while the phone is holding changes back, and they go out in order as soon as the Mac can take them.
- **Not delivered · 2** appears when a change never reached the Mac: the Mac refused it for good, or gave no answer for 24 hours ("No answer from Work Mac for 24 hours"). Tap it to open the list, oldest first.

### Retry or dismiss
Each row in the **Not delivered** list has **Retry**, which sends that change again, after anything you did since. While it runs the button is off. If it fails, the reason shows under that row: "Unlock your iPhone to retry." or "Couldn't retry. Try again."

**Dismiss All** drops every listed change for good, after you confirm ("Dismiss 2 actions? They won't be sent."). If that fails, the phone says "Couldn't dismiss. Try again."

## Related

- [iPhone](iphone.md)
- [iPhone: permission prompts and interrupts](iphone-agent-prompts.md)

For developers: [docs/features/mobile-companion.md](../../features/mobile-companion.md)
