# iPhone: Relay

Relay isn't in the current version of Watchtower for iPhone.

Relay is a paid way for your phone and your Macs to talk without waiting on iCloud. It's for anyone with a linked phone ([iPhone](iphone.md)) who wants changes sooner.

## Why use it
<!-- learn: none -->

Answer an ask on the phone and watch the session go on: over iCloud that takes tens of seconds, over Relay under a second.

## How it works
<!-- learn: none -->

Relay carries the same sealed records iCloud does, so our server can't read anything. A subscription belongs to one iPhone and holds up to 3 Macs. You choose iCloud or Relay for each Mac, and linking a subscribed iPhone chooses Relay; the choice applies to every phone of that Mac.

A subscribed iPhone newly linking a Mac on iCloud links over Relay. An older Mac or one without Relay links over iCloud, as does a full subscription (3 other Macs) if iCloud works, else the phone asks you to remove one. An already linked phone doesn't move by scanning again: use **Connection** → **Relay**.

If other phones use the Mac over iCloud, it warns first: "Linking this iPhone moves Work Mac to Relay. iPhones linked over iCloud without Relay lose their connection until they subscribe." After **Link**, the Mac moves once Relay confirms the phone pays: in seconds, or up to 5 minutes after a recent switch; until Relay answers it stays on iCloud, and the phone is linked either way. A Mac without usable iCloud still links it, and Settings → **Mobile** says so, such as "iCloud is off on this Mac. A phone with Relay can still link; linking moves this Mac to Relay."

A phone with no subscription gets no updates from a Mac on Relay. A Relay you cannot reach never switches a Mac by itself, however long it lasts: changes wait on the phone until it is back or you switch (except a phone whose subscription ended, below).

A Mac moves back to iCloud on its own in two ways. When it hears that a subscription ended, it moves if no other subscribed phone holds it, whether or not those phones work over iCloud. If it never hears, it moves only after Relay has listed no subscribed phone for it on two checks 5 minutes apart, and only when every linked phone also works over iCloud; a Relay-only phone keeps it on Relay until the Mac hears after all (a refused write, Relay's notice, or the phone's request), and then it moves by the first rule and that phone loses its connection until you link it again.

A Mac with nothing to send hears nothing and stays. A phone linked over Relay on another Apple ID, or one that lost its iCloud, loses its connection when the Mac moves: link it again, or switch the Mac back to Relay from a subscribed phone.

On the Mac, Settings → **Mobile** lists each phone as **iCloud**, **Relay** or **Waiting for Relay**, and who switched it last. Its **Relay** row says whether the Mac is connected.

## Using it
<!-- learn: none -->

### Subscribe
<!-- learn: none -->

1. On the phone, open Settings → **Towers** and tap **Relay** on the Relay card.
2. Press **Subscribe — <price> / month** and confirm in the App Store sheet.
3. When the screen says "Relay is on. Choose it for each tower in Towers.", press **Done**.

Your Macs stay where they are until you choose. A subscription whose payment has a problem reads "Active. Check your payment in the App Store." and keeps working.

### Choose Relay or iCloud for a Mac
<!-- learn: none -->

Open Settings → **Towers**, tap one, and pick **Relay** or **iCloud** under **Connection**. The row reads "Switching to Relay…" while it runs, and "Waiting for Work Mac. It switches when it's back." if that Mac is closed.

A Mac can go to Relay only 5 minutes after its last switch: "Switching to Relay is possible again in 4 min". "Your subscription already has 3 towers." means one has to leave first: **Manage towers**. A Mac that gives no answer for a day says "Work Mac didn't answer for a day, so nothing changed. Try again when it's back."

A hub with no iCloud path (a Linux box) says "This hub works over Relay only" and offers no choice.

### Move Relay to a new iPhone
<!-- learn: none -->

1. On the new iPhone, open Settings → **Towers**, tap **Relay** and press **Restore Purchases**.
2. Link each again with **Add tower** and a new code; links don't move with the subscription.

The old iPhone says the subscription moved and goes back to iCloud. A subscription can move 3 times in 30 days; past that, the phone says "This subscription moved too many times this month. Try again later."

## When it's empty or wrong
<!-- learn: none -->

### A purchase that didn't finish
<!-- learn: none -->

- **"The App Store didn't finish. Nothing changed; you can try again."** Press **Load the Price** if the price is gone, then subscribe again.
- **"Couldn't reach Relay. You weren't charged."** Press **Try Again**.
- **"Couldn't reach Relay."** after **Restore Purchases**. Press **Try Again**, which restores again.
- **"You're subscribed. Relay turns on as soon as Watchtower reaches it."** Apple charged you and Relay hasn't heard yet. It retries each time you open the app (**Try Again** does it now); until then **Towers** and **Connection** say "Your purchase isn't confirmed yet." and offer no second **Subscribe** for that period.
- **The App Store sheet closed as if you cancelled, but Apple charged you.** It goes on: the screen shows **Confirming with Relay…**, then the answer.
- **"Waiting for approval. Relay turns on when it's approved."** Someone must approve it, such as with Ask to Buy.
- **"Relay couldn't confirm this purchase. Try Restore Purchases."** Press it. If it still fails, **Manage Subscription** cancels it at Apple, and [Apple's refund page](https://reportaproblem.apple.com) refunds it.
- **"Relay can't take purchases right now. You're not charged again; try again later."** Try later, or cancel and ask for a refund as above.
- **"No subscription found on this Apple ID."** Check the Apple ID.
- **"Update Watchtower from the App Store to use Relay."** Update the app.

### "Relay unavailable" and Switch to iCloud
<!-- learn: none -->

**Now** shows "Relay unavailable for 3 min. Your changes wait on this iPhone." after a minute without an answer. After 10 minutes it adds **Switch Work Mac to iCloud**.

It moves that Mac and all its phones to iCloud once the Mac reads the request; the banner says "Switching to iCloud…". A relay-only hub gets no such button.

### "Your Relay subscription ended"
<!-- learn: none -->

When a phone's subscription ends, a Mac moves back to iCloud only if no other subscribed phone holds it in its slots (any phone you added it to while paying, linked or not); otherwise only the phone whose subscription ended leaves. If Relay cannot be reached, that phone asks for the move itself, sometimes without a press, and the Mac moves even if a subscribed phone holds it; switch it back from the Relay row on a subscribed phone. A phone without iCloud loses its connection when the Mac moves, until you link it again; a Mac that never hears of the end uses the slower check in [How it works](#how-it-works).

- **"Your Relay subscription ended. This iPhone is back on iCloud."** **Subscribe** starts again; **OK** closes it.
- **"Your Relay subscription ended. Work Mac moves to iCloud when it's back."** The Mac is closed and moves when it wakes.
- **"Your Relay subscription moved to another iPhone. This iPhone is back on iCloud."** Someone restored the purchase on another iPhone. **Restore Purchases** takes it back.
- **"Work Mac runs over Relay. This iPhone doesn't get updates from it."** Subscribe, or switch the Mac to iCloud from a subscribed phone. The line under it says when the last update came.
- **"build-box needs Relay."** That hub has no iCloud path, so it stays silent until you subscribe or restore.
- **"Update Watchtower from the App Store to keep using Relay."** Update the app.

## Related
<!-- learn: none -->

- [iPhone](iphone.md)
- [iPhone: work alerts](iphone-alerts.md)
- [iPhone: changes that are not delivered](iphone-not-delivered.md)
- [Headless host](headless-host.md)

For developers: [docs/features/relay-client.md](../../features/relay-client.md)
