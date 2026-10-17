:::artifact key="vendor-followup" kind="email" title="Follow-up: vendor contract" to="anna@example.com" cc="legal@example.com" subject="Contract \"v2\" — next steps"
Hi Anna,

Thanks for the call today. Legal has two comments on section 4; I will send the marked-up copy by Friday.

Best,
Alex
:::

:::artifact key="standup-note" kind="slack" title="Standup update" channel="1:C0123ABC" thread_ts="1727000000.000100"
Yesterday: closed PROJ-123. Today: payments rollout review. Blocked: none.
:::

:::artifact key="design-review" kind="event" title="Design review" start="2026-09-30T10:00:00+03:00" end="2026-09-30T11:00:00+03:00" attendees="anna@example.com, bohdan@example.com" location="Room 4"
Agenda: new chat layout, artifact panel, open questions.
:::

:::artifact key="launch-deck" kind="html" title="Launch deck"
<!doctype html>
<html><head><style>section{display:none}section.on{display:block}</style></head>
<body onkeydown="const s=[...document.querySelectorAll('section')],i=s.findIndex(x=>x.classList.contains('on')),n=Math.max(0,Math.min(s.length-1,i+(event.key==='ArrowRight')-(event.key==='ArrowLeft')));s[i].classList.remove('on');s[n].classList.add('on')">
<section class="on"><h1>Launch</h1></section><section><h1>Plan</h1></section>
</body></html>
:::
