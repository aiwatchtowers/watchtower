---
name: Slack today
summary: What happened today in your Slack channels
trigger:
  sync: slack_today
artifacts: living
concurrency: 1
permissions:
  - builtin:slack.window
  - llm:light
outputs: [inbox]
budget: {tokens: 150000, minutes: 5}
---
After a sync, at most once an hour, sums up today's messages in your Slack channels as one list of what was decided, what asks you and what needs someone.

```js
// Label ranks: the caps take out the lowest first, the card shows the
// highest first.
var RANK = { fyi: 0, decided: 1, needs_someone: 2, asks_you: 3 };
var BADGE = {
  asks_you: { text: "asks you", tone: "warning" },
  needs_someone: { text: "needs someone", tone: "info" },
  decided: { text: "decided", tone: "success" },
  fyi: { text: "fyi", tone: "neutral" }
};
// The state is capped at 64 KB and the card at 40 blocks: at most 6 lines
// per channel and 90 per day are kept, 18 channels shown; what the caps
// take out is counted in "more" and named on the card.
var CHANNEL_LINES = 6;
var DAY_LINES = 90;
var SHOWN_CHANNELS = 18;
var NAMED_CHANNELS = 10;
var LINE_CHARS = 160;
var TITLE_CHARS = 200;
// A quiet channel (no lines, nothing taken out) is stored as {name, n}; the
// QUIET_KEEP busiest are kept one by one, the rest folded into quiet_rest
// {channels, messages}, so a day in thousands of channels fits the state.
// v1 limit: a folded channel is forgotten — its later messages start a new
// entry counted from that run, and if it is folded again it counts again in
// quiet_rest.channels (quiet_rest.messages and the day's messages stay exact).
var QUIET_KEEP = 200;
var SCHEMA = {
  type: "object",
  required: ["lines"],
  properties: {
    lines: {
      type: "array",
      items: {
        type: "object",
        required: ["ids", "label", "text"],
        properties: {
          ids: { type: "array", items: { type: "string" }, minItems: 1, maxItems: 20 },
          label: { type: "string", enum: ["decided", "asks_you", "needs_someone", "fyi"] },
          text: { type: "string" }
        }
      }
    }
  }
};

function compare(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}

// Card order of a channel's lines: label rank, then newest first.
function lineOrder(a, b) {
  return RANK[b.label] - RANK[a.label] || compare(b.at, a.at) || compare(a.text, b.text) || compare(a.link, b.link);
}

// cut is text on one line, at most n characters, an ellipsis marking the cut.
function cut(text, n) {
  var chars = Array.from(text.replace(/\s+/g, " ").trim());
  return chars.length <= n ? chars.join("") : chars.slice(0, n - 1).join("") + "…";
}

// heading is a channel's title: "#name" for a channel; a 1:1 DM ("@name")
// and a group DM (its members' names) as they are.
function heading(name) {
  return name.charAt(0) === "@" || name.indexOf(" ") >= 0 ? name : "#" + name;
}

// MARKDOWN_CHARS are escaped in a text block's channel names (a string,
// not a regular expression: the lexical scan of LLMCallSites and PreParse
// does not tell a regular expression's backtick from a template's).
var MARKDOWN_CHARS = "\\`*_[]~<>";

function escapeMarkdown(text) {
  return Array.from(text).map(function (ch) { return MARKDOWN_CHARS.indexOf(ch) >= 0 ? "\\" + ch : ch; }).join("");
}

function plural(n, one, many) {
  return n + " " + (n === 1 ? one : many);
}

function freshDay(day) {
  return { v: 1, day: day, messages: 0, missed_yesterday: 0, channels: {}, quiet_rest: { channels: 0, messages: 0 } };
}

function isNews(c) {
  return (c.lines && c.lines.length > 0) || c.more > 0;
}

// foldQuiet stores the quiet channels compact and folds those past the
// QUIET_KEEP busiest (n desc, then name) into quiet_rest.
function foldQuiet(s) {
  var quiet = [];
  Object.keys(s.channels).forEach(function (id) {
    var c = s.channels[id];
    if (!isNews(c)) {
      s.channels[id] = { name: c.name, n: c.n };
      quiet.push(id);
    }
  });
  quiet.sort(function (a, b) {
    var ca = s.channels[a], cb = s.channels[b];
    return cb.n - ca.n || compare(ca.name, cb.name) || compare(a, b);
  });
  quiet.slice(QUIET_KEEP).forEach(function (id) {
    s.quiet_rest.channels += 1;
    s.quiet_rest.messages += s.channels[id].n;
    delete s.channels[id];
  });
}

// addLine keeps a reply line whose ids are all in the input, in its first
// message's channel.
function addLine(s, byId, line) {
  var msgs = [];
  for (var i = 0; i < line.ids.length; i++) {
    var m = byId[line.ids[i]];
    if (!m) {
      return;
    }
    msgs.push(m);
  }
  var text = cut(line.text, LINE_CHARS);
  if (!text) {
    return;
  }
  var at = msgs.reduce(function (newest, m) { return m.at > newest ? m.at : newest; }, "");
  s.channels[msgs[0].channel_id].lines.push({ label: line.label, text: text, at: at, link: msgs[0].permalink || "" });
}

// capLines keeps at most CHANNEL_LINES per channel and DAY_LINES in all,
// taking out the lowest label first, then the oldest, each counted in its
// channel's "more".
function capLines(s) {
  var all = [];
  Object.keys(s.channels).forEach(function (id) {
    var c = s.channels[id];
    c.lines.sort(lineOrder);
    if (c.lines.length > CHANNEL_LINES) {
      c.more += c.lines.length - CHANNEL_LINES;
      c.lines = c.lines.slice(0, CHANNEL_LINES);
    }
    c.lines.forEach(function (l) { all.push({ id: id, line: l }); });
  });
  if (all.length <= DAY_LINES) {
    return;
  }
  all.sort(function (a, b) { return lineOrder(a.line, b.line) || compare(a.id, b.id); });
  all.slice(DAY_LINES).forEach(function (g) {
    var c = s.channels[g.id];
    c.more += 1;
    c.lines.splice(c.lines.indexOf(g.line), 1);
  });
}

function hasLabel(c, label) {
  return c.lines.some(function (l) { return l.label === label; }) ? 1 : 0;
}

// blocksOf draws the card from the day's lines only, so a quiet message
// never changes it.
function blocksOf(s) {
  var news = [];
  Object.keys(s.channels).forEach(function (id) {
    var c = s.channels[id];
    if (isNews(c)) {
      news.push({ id: id, c: c });
    }
  });
  news.sort(function (a, b) {
    return hasLabel(b.c, "asks_you") - hasLabel(a.c, "asks_you") ||
      hasLabel(b.c, "needs_someone") - hasLabel(a.c, "needs_someone") ||
      b.c.lines.length - a.c.lines.length || compare(a.c.name, b.c.name) || compare(a.id, b.id);
  });
  var blocks = [];
  news.slice(0, SHOWN_CHANNELS).forEach(function (e) {
    var lines = e.c.lines.slice().sort(lineOrder);
    var newest = null;
    lines.forEach(function (l) {
      if (l.link && (!newest || l.at > newest.at)) {
        newest = l;
      }
    });
    var rows = lines.map(function (l) {
      var row = { title: l.text, badge: BADGE[l.label] };
      if (l.link) {
        row.link = l.link;
      }
      return row;
    });
    if (e.c.more > 0) {
      var more = { title: plural(e.c.more, "more line", "more lines") + " — open the channel to read " + (e.c.more === 1 ? "it" : "them") };
      if (newest) {
        more.link = newest.link;
      }
      rows.push(more);
    }
    blocks.push({ type: "list", title: cut(heading(e.c.name), TITLE_CHARS), rows: rows });
    if (newest) {
      blocks.push({ type: "link", title: "Open in Slack", url: newest.link });
    }
  });
  var rest = news.slice(SHOWN_CHANNELS);
  if (rest.length > 0) {
    var names = rest.slice(0, NAMED_CHANNELS).map(function (e) { return escapeMarkdown(heading(e.c.name)); });
    blocks.push({ type: "text", markdown: plural(rest.length, "more channel", "more channels") + " with news: " +
      names.join(", ") + (rest.length > NAMED_CHANNELS ? ", …" : "") });
  }
  if (news.length === 0) {
    blocks.push({ type: "list", rows: [], empty: "Nothing for you in your channels yet today" });
  }
  if (s.missed_yesterday > 0) {
    blocks.push({ type: "text", markdown: plural(s.missed_yesterday, "message", "messages") + " from late yesterday " +
      (s.missed_yesterday === 1 ? "was" : "were") + " not read." });
  }
  return blocks;
}

var w = slack.window({ floor: "today" });
var s = state.get("today");
var valid = !!s && s.v === 1;
if (w.status === "done") {
  if (!valid || s.day !== w.day) {
    s = freshDay(w.day);
  }
  s.missed_yesterday += w.below_floor;
  // In memory every channel has lines and more; foldQuiet compacts them.
  Object.keys(s.channels).forEach(function (id) {
    var c = s.channels[id];
    c.lines = c.lines || [];
    c.more = c.more || 0;
  });
  var byId = {};
  var input = [];
  w.messages.forEach(function (m) {
    var c = s.channels[m.channel_id];
    if (!c) {
      c = s.channels[m.channel_id] = { name: "", n: 0, more: 0, lines: [] };
    }
    c.name = m.channel.replace(/^#/, "");
    c.n += 1;
    s.messages += 1;
    if (m.to_owner) {
      return;
    }
    byId[m.id] = m;
    input.push({ id: m.id, channel: m.channel, author: m.author, time: m.time, text: m.text,
      thread_id: m.thread_id, by_owner: m.by_owner, bot: m.bot });
  });
  if (input.length > 0) {
    var reply = llm(builtin.defaultPrompt("label"), { input: { owner: w.owner, messages: input }, schema: SCHEMA, tier: "light" });
    reply.lines.forEach(function (line) { addLine(s, byId, line); });
    capLines(s);
  }
  foldQuiet(s);
  state.set("today", s);
} else if (!valid) {
  // The window was skipped (Slack off by policy) before any day: an empty
  // card, no state.
  s = freshDay("");
}

output.inbox({ key: "slack-today", title: "Slack today", blocks: blocksOf(s) });
```
