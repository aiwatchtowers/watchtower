# The iPhone is not syncing

The phone shows "Mac offline", never finds the Mac, an answered ask stays on **Waiting for your Mac**, or the link code is refused.

## What you see

- On **Now**: "Mac online · 12s", "Mac offline · 13m" or "Mac not connected".
- A change that stays at **Waiting for your Mac**.
- While linking: "This code expired", "This code can't be used", or "Sign in to iCloud on this iPhone to use Watchtower".
- On the Mac, **Settings → Mobile** shows why Mobile is off, **Needs a signed build**, "iCloud is slowing sync down", "Paused until iCloud is available on this Mac." or "Mobile is run by a newer Watchtower".
- "<Mac> hasn't synced for a day" or "<Mac> removed this phone".
- On a Mac that runs over Relay, **Settings → Mobile** shows "Relay unavailable for <N> min.", "This Mac's Relay storage is full (5 GB).", "<phone>'s Relay mailbox is full.", "Doesn't get updates: this Mac runs over Relay.", "On this Mac's side, <N> actions from this phone are not applied yet." or "Notifications aren't set up on this iPhone."

## Why

The Mac is the hub. It publishes your data into your iCloud and applies the phone's changes only while Watchtower runs on an awake Mac with **Mobile sync** on. The phone calls the Mac online while its heartbeat, written every 15 minutes, is under 35 minutes old. Quitting Watchtower or sleeping the Mac stops the hub; closing the window does not. Over Relay, only a phone with a Relay subscription gets updates, and the relay keeps a limited amount of storage for the Mac and for each phone.

## Fix

1. On the Mac, open Watchtower (closing the window is fine), keep the Mac awake and open **Settings → Mobile**. Turn on **Mobile sync**.
2. **Needs a signed build:** the Mac build has no iCloud signing, so it cannot use iCloud; phones on Relay keep working. Use the downloaded Developer ID app.
3. Check iCloud: both devices must be signed in to iCloud. A Mac with iCloud off says "Mobile isn't available on this Mac: iCloud is off." A Mac whose iCloud account can't be used for now says "Paused until iCloud is available on this Mac. It goes on by itself.": sign in to iCloud on the Mac, or wait.
4. The phone never sees the Mac: check the build pairing. The downloaded Mac app pairs with a TestFlight or App Store phone. A phone run from Xcode pairs only with a Mac built for the Development environment; mixed pairs fail silently.
5. **Code expired or can't be used:** press **New code** on the Mac and scan again. A code lasts 10 minutes and works for one phone.
6. **Waiting for your Mac:** wake the Mac. Pending changes apply when it wakes, and the Mac checks for them every 30 seconds.
7. **Hasn't synced for a day:** if the Mac changed its iCloud account, link again.
8. **Removed this phone:** that hub is frozen. Tap **Forget** on the phone and link again with **Add Mac**.
9. **iCloud is slowing sync down:** wait; it clears on its own.
10. **Mobile is run by a newer Watchtower:** you opened an older Watchtower after an update moved the iPhone sync to the new version. This older app leaves the phone alone. Install the latest Watchtower and open it; the phone keeps its link.
11. **Relay unavailable for <N> min.:** the Mac cannot reach the relay. Check the Mac's internet connection; phones keep their changes and send them when it is back.
12. **This Mac's Relay storage is full (5 GB):** the Mac's space on the relay holds what your phones see, including each meeting transcript from the last 30 days. In Watchtower on the Mac, open each recording you no longer need and click **Delete**. The line clears at the Mac's next change that the relay accepts.
13. **<phone>'s Relay mailbox is full:** the Mac's replies to that phone are piling up unread. Open Watchtower on that phone so it reads them.
14. **Doesn't get updates: this Mac runs over Relay:** that phone has no Relay subscription. Subscribe on it, or switch the Mac to iCloud from a subscribed phone.
15. **On this Mac's side, <N> actions from this phone are not applied yet:** the Mac holds them until the phone sends the ones before them. Open Watchtower on the phone and keep it online until the line goes away.
16. **Notifications aren't set up on this iPhone:** open Watchtower on that iPhone once.

## How to check

**Now** reads "Mac online" with a small age, and a waiting change leaves **Waiting for your Mac**. Over Relay, the Mac's **Relay** row reads "Connected · last change delivered <age> ago" (just "Connected" before the first change) and the phone's row shows no warning line.

## If it did not help

A phone on another Apple ID needs the Mac's iCloud share to work; if you see "This Mac can't share with another Apple ID right now", show a new code and try again. The full list of messages is on [iPhone](../features/iphone.md).
