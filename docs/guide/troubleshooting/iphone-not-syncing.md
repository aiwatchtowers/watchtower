# The iPhone is not syncing

The phone shows "Mac offline", never finds the Mac, an answered ask stays on **Waiting for your Mac**, or the link code is refused.

## What you see

- On **Now**: "Mac online · 12s", "Mac offline · 13m" or "Mac not connected".
- A change that stays at **Waiting for your Mac**.
- While linking: "This code expired", "This code can't be used", or "Sign in to iCloud on this iPhone to use Watchtower".
- On the Mac, **Settings → Mobile** shows **Needs a signed build** or "iCloud is slowing sync down".
- "<Mac> hasn't synced for a day" or "<Mac> removed this phone".

## Why

The Mac is the hub. It publishes your data into your iCloud and applies the phone's changes only while Watchtower runs on an awake Mac with **Sync with iPhone** on. The phone calls the Mac online while its heartbeat, written every 15 minutes, is under 35 minutes old. Quitting Watchtower or sleeping the Mac stops the hub; closing the window does not.

## Fix

1. On the Mac, open Watchtower (closing the window is fine), keep the Mac awake and open **Settings → Mobile**. Turn on **Sync with iPhone**.
2. **Needs a signed build:** the Mac build has no iCloud signing and cannot turn sync on. Use the downloaded Developer ID app.
3. Check iCloud: both devices must be signed in to iCloud. A Mac with iCloud off says "Mobile isn't available on this Mac: iCloud is off."
4. The phone never sees the Mac: check the build pairing. The downloaded Mac app pairs with a TestFlight or App Store phone. A phone run from Xcode pairs only with a Mac built for the Development environment; mixed pairs fail silently.
5. **Code expired or can't be used:** press **New code** on the Mac and scan again. A code lasts 10 minutes and works for one phone.
6. **Waiting for your Mac:** wake the Mac. Pending changes apply when it wakes, and the Mac checks for them every 30 seconds.
7. **Hasn't synced for a day:** if the Mac changed its iCloud account, link again.
8. **Removed this phone:** that hub is frozen. Tap **Forget** on the phone and link again with **Add Mac**.
9. **iCloud is slowing sync down:** wait; it clears on its own.

## How to check

**Now** reads "Mac online" with a small age, and a waiting change leaves **Waiting for your Mac**.

## If it did not help

A phone on another Apple ID needs the Mac's iCloud share to work; if you see "This Mac can't share with another Apple ID right now", show a new code and try again. The full list of messages is on [iPhone](../features/iphone.md).
