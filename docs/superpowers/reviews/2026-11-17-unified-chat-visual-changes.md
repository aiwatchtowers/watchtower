# Unified chat addendum — visible changes for the owner's review (2026-11-17, #1822 T16)

The addendum moved the composer (T13), the approval card (T15) and the routing pill (T17) into `ChatUI`, one implementation for the Mac and the iPhone (asks #1409, #1411, #1418, #1420). This page lists every change a person can see, frame by frame, so the owner can accept or decline each one in a single review. Feature note: [unified-chat.md](../../features/unified-chat.md).

For each change: the frame that shows it, one line on what changed, and whether a style hook can turn it off if the owner declines. "Hook" means a `ChatUIStyle` method that the phone's `PhoneChatStyle` or the Mac's `DesignKitChatStyle` can override in a follow-up commit, with no change to shared logic. "No" means the change is a rule or copy that the owner already decided, or it comes from the one shared catalog; undoing it is a code change, not a style override.

How the frames were made:
- Mac: `DesignShotsTests` (`testComposerShotsRender`, `testApprovalCardShotsRender`, `testRoutingShotsRender`).
- Phone: `make mobile-shots SHOTS_ONLY=chat` on a dedicated iPhone 17 Pro simulator (iOS 26.4).
- Base is the umbrella before the addendum (`3feab0493`, plus the tour harness's suspending-sleep fix from T15 so the C2 frames render at all). HEAD is the umbrella with T13, T14, T15, T17 and this task (`feature/unified-chat-t16`).
- Pixel diffs used a CoreGraphics compare. Differences only in the iOS 26 glass tab bar, the back button's glass, a loading spinner, a relative timestamp or the pulsing dictation highlight are capture artifacts, not changes, and are not listed.

## Mac

The Mac's look is unchanged in every rendered frame. All composer, approval-card and routing shots match their base pixel for pixel, apart from the artifacts above. The changes below are behaviour or copy that no shot covers.

| # | Frame | What changed | Can a hook turn it off? |
|---|---|---|---|
| M1 | `composer-main-editing` (base and HEAD, identical) | Brief asked to check the editing and over-limit lines that `ChatUI`'s composer now draws. The editing line is pixel-identical to base. | n/a (no change) |
| M2 | no frame (over 32 000 characters) | Send is now off past the 32 000-character cap, and the status line says why (`ChatComposerModel.overLimitLine`). Before, Send looked live and did nothing (T13 m9). | No: model rule. |
| M3 | no frame (attach refused) | An attachment refusal now starts with the file name: `"<name>: <reason>"` (both devices, T13). | No: model copy. |
| M4 | no frame (target chat, automation editor) | A Slack send that still needs a workspace pick, on a Mac surface without the picker, used to show "exists in N workspaces, choose one" with an Approve that Go refused. It now shows "Choose a workspace in Inbox › Needs approval before approving" and only Reject (T15 I-2; the wording is T16's carry, which replaced "Choose a workspace on the Mac before approving", a dead end on the Mac itself). | Copy only: `ChatHostText.mac.chooseSlackWorkspace`. The missing Approve is the Inbox row's existing rule. |
| M5 | no visible difference (`approval-*` identical) | **Approve all** shows under a reply whose own approval parts hold two or more bulk-approvable cards; before, it counted every pending row of the turn. When it and the reviewed actions both show under one reply, the gap between them is now the feed's row spacing instead of 8 pt (T15). | No: rule. |

## iPhone — composer (T13)

| # | Frame | What changed | Can a hook turn it off? |
|---|---|---|---|
| P1 | `C2i-chat-quote` (base and HEAD) | A waiting quote is now the Mac's quote batch card (the italic quote, a **Comment (optional)** field, a remove button) instead of a `“…”` chip. It still sits under the model and project chips. | Yes: `quoteRow` (`PhoneChatStyle` can draw the old chip). |
| P2 | `iphone-chat-composer-mentions` (new) | `@` mentions now show as chips on the phone (new), and mention and skill chips sit in one horizontal scroll row. | Partly: `composerChip` restyles each chip; the row itself is shared. |
| P3 | `iphone-chat-composer-attachments` (new) | File pill icons follow the file type (`doc.text`, `doc.richtext`, `photo`; was `doc` or `photo`). | Yes: `attachmentChip` (already a `PhoneChatStyle` override). |
| P4 | no frame (transient) | While a send is in flight the button reads a disabled **Stop** instead of a disabled **Send**: the Mac's `isBusy` rule (T13 m1). It lasts until the echo, at most the 10 s reconnect patience. | Partly: `sendStopButton(isStreaming:active:)` could show Send while `!active`, but that also covers a running turn that cannot be stopped. |
| P5 | no frame | `/` picker rows read "review" instead of "/review" (the Mac's row title); the picked chip still reads "/review" (T13 m2). | Yes: `pickerList`. |
| P6 | `iphone-chat-composer-quotes` (new) | New frame of the quote batch with more than one quote; same change as P1. | Yes: `quoteRow`. |

## iPhone — approval card (T15)

| # | Frame | What changed | Can a hook turn it off? |
|---|---|---|---|
| P7 | `C2c-chat-approvals` (base and HEAD), `iphone-chat-approval-slack` | Card titles come from the one tool catalog ("Send to Slack", "Move a Jira issue") instead of the engine's title. Bodies show summary lines ("To: #release in acme" and the message; "Issue: PROJ-12 → Done") instead of raw monospaced args. The frame, the orange status and the buttons are unchanged. | No: the one catalog (A1). `approvalHeader` restyles the header, not its title. |
| P8 | `iphone-chat-approval-jira` (new) | A Jira proposal's fields as the Mac shows them. | No: new content. |
| P9 | `iphone-chat-approval-confluence` (new) | A Confluence edit's word diff, as on the Mac. A clipped edit shows "This page edit is too long to show in full here." and still offers Approve, pinned to the args digest (ask #1420). | No: owner decision. |
| P10 | `iphone-chat-approval-connector` (new) | A claude.ai connector call's input, read-only. With no running turn it says **Chat session ended** and offers no Approve (the Mac's rule). | No: rule. |
| P11 | `iphone-chat-approval-settled` (new) | A settled card shows its outcome and links. | No: new content. |
| P12 | `iphone-chat-approval-no-permission` (new) | Without the phone's answer permission the card says **Approve on the Mac** (unchanged copy, new frame). | n/a |
| P13 | no frame (an awaited card) | The card the running turn waits on is outlined on the phone too. | Yes: `approvalCard(_:outlined:)` can ignore `outlined`. |
| P14 | no frame (Slack with candidates, no pick) | A Slack send whose workspace is not chosen says "Choose a workspace on <tower> before approving" and offers only Reject. Before, the phone also offered an Approve that the engine refuses for an unpicked send. | Copy only: `ChatHostText.phone`. |

The phone has no approval editing and no **Approve all**, **Dismiss** or **Retry**: owner-confirmed v1 limits (ask #1411), not changes.

## iPhone — routing pill (T17)

| # | Frame | What changed | Can a hook turn it off? |
|---|---|---|---|
| P15 | `C2h-chat-new` (base and HEAD), `iphone-chat-routing-new-chat` | The model chip reads the Mac's copy: "Preferred + reserve · Auto" (was "Auto · Claude"), or "Only <Provider> · <model>" when pinned. | No: Mac copy on both devices (ask #1418). `routingPillLabel` restyles the label, not its words. |
| P16 | `C2a-chat-done` (base and HEAD), `iphone-chat-routing-saved` | On a saved chat the pill is a menu (tinted ⌄), editable between turns; the project chip stays locked text. | No: ask #1418. |
| P17 | `C2a-chat-done` (base and HEAD) | A saved chat with a known actual provider shows "Current provider: <Provider>[ · model]" above the pill. This moves the feed up by one line, hence the large pixel counts in C2a–f and C2i. | Partly: `routingCaption(_:warning:)` gets the line, but the missing-capabilities line comes through the same call with `warning: false`, so hiding only this line needs a new hook parameter. |
| P18 | `iphone-chat-routing-fallback` (new) | The fallback card when the preferred provider hit its limit, with the claude.ai-tools notice. | Yes: `routingStatusCard`. |
| P19 | `iphone-chat-routing-recovered` (new) | The preferred provider can be tried again: **Use Claude** (`chat_manage use_preferred`). | Yes: `routingStatusCard` (the action stays in the model). |
| P20 | `iphone-chat-routing-unsupported`, `-missing-caps`, `-status-error`, `-offline`, `-no-catalog` (new) | The other states: a provider that cannot serve the request, missing capabilities, "Couldn't read provider availability", the action off while offline, and an older daemon with no `routing` (model choice only). | Yes: `routingStatusCard`, `routingCaption`. |

v1 limits, not changes: the phone's model menu lists the registry's models only (no live Ollama list), and its provider availability refreshes only when `chat_list` is rebuilt (no "check again", no refresh on app activation).

## Images

The PNGs are not in the repository. They were copied, light mode only (the dark and narrow variants exist in the render folders), to the reviewer's scratch folder; the controller attaches them to the review ask. Names are `<#>-<frame>-<base|head>.png`.
