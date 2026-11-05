# iPhone: work alerts

The Watchtower iPhone app can tell you when a Workbench session needs you or has stopped, and a tap on the alert takes you to the right place. It is for anyone who already linked a phone (see [iPhone](iphone.md)).

## Why use it
<!-- learn: none -->

You leave the Mac while a session works. When it asks a question, needs a permission answer or stops, the phone buzzes, and you answer from the lock screen instead of finding out an hour later.

## How it works
<!-- learn: none -->

Your Mac decides when to alert, and only while you are away from it. Its alert travels the way the phone syncs.

### Alerts over Relay
<!-- learn: none -->

Relay isn't in the current version of Watchtower for iPhone.

When your Mac runs over Relay, each alert is pushed through the relay to every linked phone with a Relay subscription, once per phone. The push is sealed: the relay and Apple see only the word **Watchtower**, and the phone opens the title and text itself.

A phone gets these pushes only after Watchtower was opened on it once. Very long text is shortened in the push; the ask itself stays complete. An alert that cannot be sent within 5 minutes is dropped rather than arriving late, and none is sent once you are back at the Mac.

Turning **When work stops** off on the phone asks the Mac to stop sending it these pushes, because the relay's push address also carries the phone's silent updates and the phone can't drop one without the other. A Mac switch from Relay to iCloud can bring one alert twice.

If the Mac shows "Relay has no notifications configured.", the relay this Mac uses cannot send pushes; the ask or the stopped session still shows in the app. A phone without a Relay subscription gets no alerts while the Mac runs over Relay, and no updates at all: see [The iPhone is not syncing](../troubleshooting/iphone-not-syncing.md). More on [iPhone: Relay](iphone-relay.md).

## Using it

### Get alerts when work stops
<!-- learn
id: iphone-alerts-work-stops
title: Get an alert when work stops
text: Away from the Mac, the phone alerts you when a session asks, needs approval, stops or fails.
area: iphone
level: next
kind: feature
since: 0.26.0
-->

Settings → **Notifications** → **When work stops** (on by default) alerts you when a session asks, needs a permission answer, stops or fails, but only while you are away from your Mac (locked, display asleep or idle for 3 minutes). A stop alerts once, after 20 seconds. A finished or stopped session that you left on the Mac alerts when you leave only if it stopped in the last 30 minutes. A phone on another Apple ID than the Mac gets its alerts when it next syncs, so they may come late, or only when you open the app; Settings says so. Unlinking a Mac removes its alerts.

### Open an alert

Tap an alert about an ask to open that ask. Tap an alert about a permission prompt, a stopped session or a failed session to open the session. If the alert came from another Mac you linked, the phone switches to that Mac first.

While the app is open, an alert shows as a banner with a sound, except when its own screen is already in front of you.

### Alerts that settle themselves

An alert leaves Notification Center once there is nothing left to do: the ask was answered, the permission prompt was answered, or the session started working again. You do not have to clear them by hand.

## When it's empty or wrong
<!-- learn: none -->

- **No alerts while you sit at the Mac.** By design: alerts come only while you are away from it.
- **The Mac shows "Notifications aren't set up on this iPhone. Open Watchtower on it once."** under a phone in Settings → **Mobile**. Open Watchtower on that iPhone once; the next alert reaches it.

## Related

- [iPhone](iphone.md)
- [iPhone: the workchat](iphone-workbench.md)
- [iPhone: permission prompts and interrupts](iphone-agent-prompts.md)

For developers: [docs/features/mobile-companion.md](../../features/mobile-companion.md)
