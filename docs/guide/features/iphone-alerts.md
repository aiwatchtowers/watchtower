# iPhone: work alerts

The Watchtower iPhone app can tell you when a Workbench session needs you or has stopped, and a tap on the alert takes you to the right place. It is for anyone who already linked a phone (see [iPhone](iphone.md)).

## Using it

### Get alerts when work stops

Settings → **Notifications** → **When work stops** (on by default) alerts you when a session asks, needs a permission answer, stops or fails, but only while you are away from your Mac (locked, display asleep or idle for 3 minutes). A stop alerts once, after 20 seconds. A finished or stopped session that you left on the Mac alerts when you leave only if it stopped in the last 30 minutes. A phone on another Apple ID than the Mac gets no alerts yet; Settings says so. Unlinking a Mac removes its alerts.

### Open an alert

Tap an alert about an ask to open that ask. Tap an alert about a permission prompt, a stopped session or a failed session to open the session. If the alert came from another Mac you linked, the phone switches to that Mac first.

While the app is open, an alert shows as a banner with a sound, except when its own screen is already in front of you.

### Alerts that settle themselves

An alert leaves Notification Center once there is nothing left to do: the ask was answered, the permission prompt was answered, or the session started working again. You do not have to clear them by hand.

## Related

- [iPhone](iphone.md)
- [iPhone: the workchat](iphone-workbench.md)
- [iPhone: permission prompts and interrupts](iphone-agent-prompts.md)

For developers: [docs/features/mobile-companion.md](../../features/mobile-companion.md)
