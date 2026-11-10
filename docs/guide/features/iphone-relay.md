# iPhone: Relay

Relay isn't in the current version of Watchtower for iPhone.

Relay is a paid way for your phone and your Macs to talk without waiting on iCloud. This page is for anyone with a linked phone who wants changes to arrive sooner (see [iPhone](iphone.md)).

## Why use it
<!-- learn: none -->

You answer an ask on the phone and watch the session go on. Over iCloud, that round trip takes tens of seconds. Over Relay, changes reach your phone in under a second.

## How it works
<!-- learn: none -->

Relay carries the same sealed records iCloud does, so our server can't read anything. A subscription belongs to one iPhone and holds up to 3 Macs. You choose iCloud or Relay for each Mac, and the choice applies to every phone of that Mac.

A phone with no subscription gets no updates from a Mac on Relay. A Relay you cannot reach never switches a Mac by its own signal, however long it lasts: your changes wait on the phone until it is back or you switch. The one exception is a phone whose subscription ended: it can ask for the move itself, and then the Mac moves even while Relay cannot be reached (see the end of this page). A Mac moves back to iCloud on its own in two ways. When a subscription ends and the Mac hears of it, one check decides: no other subscribed phone holds this Mac, and it moves, whether or not those phones work over iCloud. If the Mac never hears (the notice was lost), it moves only after Relay has listed no subscribed phone for it on two checks five minutes apart, and only when every phone linked to it also works over iCloud; a phone that works over Relay only keeps the Mac on Relay then, but only until the Mac hears after all: Relay refuses something the Mac writes to a phone, Relay tells it, or the phone asks. The Mac then moves by the first rule, and that phone loses its connection until you link it again. A Mac with nothing to send hears nothing and stays. Either way a phone that lost its iCloud since you linked it can lose its connection when the Mac moves: link it again, or switch the Mac back to Relay from a subscribed phone.

On the Mac, Settings → **Mobile** lists each phone as **iCloud**, **Relay** or **Waiting for Relay**, and who switched it last. Its **Relay** row says whether the Mac is connected.

## Using it
<!-- learn: none -->

### Subscribe
<!-- learn: none -->

1. On the phone, open Settings → **Macs** and tap **Relay** on the Relay card.
2. Press **Subscribe — <price> / month** and confirm in the App Store sheet.
3. When the screen says "Relay is on. Choose it for each Mac in Macs.", press **Done**.

Your Macs stay where they are until you choose. A subscription whose payment has a problem reads "Active. Check your payment in the App Store." and keeps working.

### Choose Relay or iCloud for a Mac
<!-- learn: none -->

Open Settings → **Macs**, tap the Mac, and pick **Relay** or **iCloud** under **Connection**. The row reads "Switching to Relay…" while it runs, and "Waiting for Work Mac. It switches when it's back." if that Mac is closed.

A Mac can go to Relay only 5 minutes after its last switch: "Switching to Relay is possible again in 4 min". "Your subscription already has 3 Macs." means one has to leave first: **Manage Macs**. A Mac that gives no answer for a day says "Work Mac didn't answer for a day, so nothing changed. Try again when it's back."

A hub with no iCloud path, such as a Linux box, says "This hub works over Relay only" and offers no choice.

### Move Relay to a new iPhone
<!-- learn: none -->

1. On the new iPhone, open Settings → **Macs**, tap **Relay** and press **Restore Purchases**.
2. Link each Mac again: **Add Mac**, then scan a new code on that Mac. Links don't move with the subscription.

The old iPhone says the subscription moved and goes back to iCloud. A subscription can move 3 times in 30 days; past that, the phone says "This subscription moved too many times this month. Try again later."

## When it's empty or wrong
<!-- learn: none -->

### A purchase that didn't finish
<!-- learn: none -->

- **"The App Store didn't finish. Nothing changed; you can try again."** Press **Load the Price** if the price is gone, then subscribe again.
- **"Couldn't reach Relay. You weren't charged."** Press **Try Again**.
- **"Couldn't reach Relay."** after **Restore Purchases**. Press **Try Again**, which restores again.
- **"You're subscribed. Relay turns on as soon as Watchtower reaches it."** Apple charged you and Relay hasn't heard yet. Relay retries each time you open the app, and **Try Again** does it now. Until then, Settings → **Macs** and the Mac's **Connection** say "Your purchase isn't confirmed yet." The screen offers no second **Subscribe** for that paid period.
- **"Waiting for approval. Relay turns on when it's approved."** The purchase waits for someone to approve it, such as Ask to Buy.
- **"Relay couldn't confirm this purchase. Try Restore Purchases."** Press **Restore Purchases**. If it still fails, **Manage Subscription** cancels it at Apple, and you can ask for a refund at [Apple's refund page](https://reportaproblem.apple.com).
- **"Relay can't take purchases right now. You're not charged again; try again later."** Try later, or use **Manage Subscription** and the refund page above.
- **"No subscription found on this Apple ID."** Restore looked and found nothing. Check the Apple ID.
- **"Update Watchtower from the App Store to use Relay."** Update the app.

### "Relay unavailable" and Switch to iCloud
<!-- learn: none -->

**Now** shows "Relay unavailable for 3 min. Your changes wait on this iPhone." after the relay has given no answer for a minute. After 10 minutes it adds **Switch Work Mac to iCloud**.

The switch moves that Mac, and every phone of it, to iCloud once the Mac reads the request. The banner then says "Switching to iCloud…". A relay-only hub has nowhere to go, so it gets no such button.

### "Your Relay subscription ended"
<!-- learn: none -->

When a phone's subscription ends, a Mac moves back to iCloud only if no other subscribed phone holds that Mac in its slots, which is every phone you added it to under a paying subscription, whether or not you linked that phone to this Mac; a subscribed phone keeps the Mac on Relay, and only the phone whose subscription ended leaves. The exception is a Relay that cannot be reached: the phone whose subscription ended asks for the move itself, sometimes without you pressing anything, and then the Mac moves even if a subscribed phone holds it. Switch it back from the Relay row on a subscribed phone. A phone without iCloud loses its connection when the Mac moves, until you link it again. If the Mac never hears that the subscription ended, the slower check described earlier on this page applies instead (two checks, and every phone must work over iCloud), until the Mac does hear.

- **"Your Relay subscription ended. This iPhone is back on iCloud."** Everything works over iCloud. **Subscribe** starts again; **OK** closes the message.
- **"Your Relay subscription ended. Work Mac moves to iCloud when it's back."** The Mac is closed, and it moves when it wakes.
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
