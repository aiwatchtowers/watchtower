---
name: Slack today
summary: What happened today in your Slack channels and DMs
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
After a sync, at most once an hour, sums up today's messages in your Slack channels and DMs as one list of what was decided, what asks you and what needs someone.

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
// A channel whose lines the caps all took out is stored as {name, n, more,
// link}; the MORE_KEEP with the most taken out are kept, the rest folded
// into more_rest {channels, lines} (the same v1 limit as quiet channels).
var MORE_KEEP = 20;
// STATE_BUDGET is the state's 64 KB less room for the window cursor and the
// counters' digits: past it, fitBudget folds quiet channels, then more-only
// channels, then takes out lines, so a run never fails on the state's size.
var STATE_BUDGET = 64 * 1024 - 1024;
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
  return { v: 1, day: day, messages: 0, missed_earlier: 0, skipped_older: 0, channels: {},
    quiet_rest: { channels: 0, messages: 0 }, more_rest: { channels: 0, lines: 0 } };
}

function linesOf(c) {
  return c.lines || [];
}

function isNews(c) {
  return linesOf(c).length > 0 || c.more > 0;
}

// utf8Bytes is str's size once the state is stored: UTF-8, with < > & and
// U+2028/U+2029 escaped as \uXXXX as Go's encoder writes them.
function utf8Bytes(str) {
  var n = 0;
  for (var i = 0; i < str.length; i++) {
    var c = str.charCodeAt(i);
    if (c === 0x3c || c === 0x3e || c === 0x26 || c === 0x2028 || c === 0x2029) {
      n += 6;
    } else if (c < 0x80) {
      n += 1;
    } else if (c < 0x800 || (c >= 0xd800 && c <= 0xdfff)) {
      n += 2;
    } else {
      n += 3;
    }
  }
  return n;
}

function jsonBytes(v) {
  return utf8Bytes(JSON.stringify(v));
}

// entryBytes is what channel id's entry costs in the state, its comma included.
function entryBytes(s, id) {
  return jsonBytes(id) + 1 + jsonBytes(s.channels[id]) + 1;
}

function foldQuietEntry(s, id) {
  s.quiet_rest.channels += 1;
  s.quiet_rest.messages += s.channels[id].n;
  delete s.channels[id];
}

function foldMoreEntry(s, id) {
  s.more_rest.channels += 1;
  s.more_rest.lines += s.channels[id].more;
  delete s.channels[id];
}

// compactDay stores the day as the state holds it: a channel with lines
// keeps {name, n, more, lines} (and link only when no line has one), a
// more-only channel {name, n, more, link}, a quiet one {name, n}; quiet
// channels past the QUIET_KEEP busiest (n desc, then name) and more-only
// ones past the MORE_KEEP with the most taken out (more desc, n desc, then
// name) are folded; then fitBudget.
function compactDay(s) {
  var quiet = [];
  var moreOnly = [];
  Object.keys(s.channels).forEach(function (id) {
    var c = s.channels[id];
    if (c.lines.length > 0) {
      if (!c.link || c.lines.some(function (l) { return !!l.link; })) {
        delete c.link;
      }
    } else if (c.more > 0) {
      s.channels[id] = { name: c.name, n: c.n, more: c.more, link: c.link || "" };
      moreOnly.push(id);
    } else {
      s.channels[id] = { name: c.name, n: c.n };
      quiet.push(id);
    }
  });
  quiet.sort(function (a, b) {
    var ca = s.channels[a], cb = s.channels[b];
    return cb.n - ca.n || compare(ca.name, cb.name) || compare(a, b);
  });
  moreOnly.sort(function (a, b) {
    var ca = s.channels[a], cb = s.channels[b];
    return cb.more - ca.more || cb.n - ca.n || compare(ca.name, cb.name) || compare(a, b);
  });
  quiet.splice(QUIET_KEEP).forEach(function (id) { foldQuietEntry(s, id); });
  moreOnly.splice(MORE_KEEP).forEach(function (id) { foldMoreEntry(s, id); });
  fitBudget(s, quiet, moreOnly);
}

// fitBudget keeps the state under STATE_BUDGET: it folds the least busy
// quiet channels, then the more-only channels with the least taken out,
// then takes out lines, lowest label and oldest first, into "more".
function fitBudget(s, quiet, moreOnly) {
  var size = jsonBytes(s);
  while (size > STATE_BUDGET && quiet.length > 0) {
    var q = quiet.pop();
    size -= entryBytes(s, q);
    foldQuietEntry(s, q);
  }
  while (size > STATE_BUDGET && moreOnly.length > 0) {
    var m = moreOnly.pop();
    size -= entryBytes(s, m);
    foldMoreEntry(s, m);
  }
  if (size <= STATE_BUDGET) {
    return;
  }
  var all = [];
  Object.keys(s.channels).forEach(function (id) {
    linesOf(s.channels[id]).forEach(function (l) { all.push({ id: id, line: l }); });
  });
  all.sort(function (a, b) { return lineOrder(a.line, b.line) || compare(a.id, b.id); });
  while (size > STATE_BUDGET && all.length > 0) {
    var g = all.pop();
    var c = s.channels[g.id];
    size -= jsonBytes(g.line) + 1;
    c.more += 1;
    c.lines.splice(c.lines.indexOf(g.line), 1);
  }
}

// addLine keeps a reply line whose ids are all in the input, in its first
// message's channel; a line it drops (an id not in the input, or no text)
// is counted in dropped with its ids.
function addLine(s, byId, line, dropped) {
  var msgs = [];
  var unknown = [];
  line.ids.forEach(function (id) {
    if (byId[id]) {
      msgs.push(byId[id]);
    } else {
      unknown.push(id);
    }
  });
  var text = cut(line.text, LINE_CHARS);
  if (unknown.length > 0 || !text) {
    dropped.lines += 1;
    dropped.ids = dropped.ids.concat(unknown.length > 0 ? unknown : line.ids);
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
  return linesOf(c).some(function (l) { return l.label === label; }) ? 1 : 0;
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
      linesOf(b.c).length - linesOf(a.c).length || compare(a.c.name, b.c.name) || compare(a.id, b.id);
  });
  var blocks = [];
  news.slice(0, SHOWN_CHANNELS).forEach(function (e) {
    var lines = linesOf(e.c).slice().sort(lineOrder);
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
    // The newest line's link, else the newest message's the channel keeps.
    var link = newest ? newest.link : e.c.link || "";
    if (e.c.more > 0) {
      var more = { title: plural(e.c.more, "more line", "more lines") + " — open the channel to read " + (e.c.more === 1 ? "it" : "them") };
      if (link) {
        more.link = link;
      }
      rows.push(more);
    }
    blocks.push({ type: "list", title: cut(heading(e.c.name), TITLE_CHARS), rows: rows });
    if (link) {
      blocks.push({ type: "link", title: "Open in Slack", url: link });
    }
  });
  var rest = news.slice(SHOWN_CHANNELS);
  if (rest.length > 0) {
    var names = rest.slice(0, NAMED_CHANNELS).map(function (e) { return escapeMarkdown(heading(e.c.name)); });
    blocks.push({ type: "text", markdown: plural(rest.length, "more conversation", "more conversations") + " with news: " +
      names.join(", ") + (rest.length > NAMED_CHANNELS ? ", …" : "") });
  }
  var moreRest = s.more_rest || { channels: 0, lines: 0 };
  if (moreRest.channels > 0) {
    blocks.push({ type: "text", markdown: plural(moreRest.lines, "more line", "more lines") + " in " +
      plural(moreRest.channels, "other conversation", "other conversations") + "." });
  }
  if (news.length === 0 && moreRest.channels === 0) {
    blocks.push({ type: "list", rows: [], empty: "Nothing for you in your channels or DMs yet today" });
  }
  // What the window passed over: messages past the cursor before local
  // midnight (a backfill, a new account, a Mac off over a weekend), and
  // ones older than the window's seven days.
  var missed = [];
  if (s.missed_earlier > 0) {
    missed.push(plural(s.missed_earlier, "earlier message", "earlier messages") + " " +
      (s.missed_earlier === 1 ? "was" : "were") + " not read");
  }
  if (s.skipped_older > 0) {
    missed.push(plural(s.skipped_older, "older message", "older messages") + " skipped");
  }
  if (missed.length > 0) {
    blocks.push({ type: "text", markdown: missed.join("; ") + "." });
  }
  return blocks;
}

var w = slack.window({ floor: "today" });
var s = state.get("today");
var valid = !!s && s.v === 1;
if (w.status === "done") {
  // A reset cursor (the messages table lost its newest rows) re-reads
  // everything since local midnight: the day starts over, so nothing is
  // counted twice.
  if (!valid || s.day !== w.day || w.cursor_reset) {
    s = freshDay(w.day);
  }
  s.missed_earlier = (s.missed_earlier || 0) + w.below_floor;
  s.skipped_older = (s.skipped_older || 0) + w.skipped_older;
  s.quiet_rest = s.quiet_rest || { channels: 0, messages: 0 };
  s.more_rest = s.more_rest || { channels: 0, lines: 0 };
  // In memory every channel has lines, more and the newest message's link;
  // compactDay stores them compact.
  Object.keys(s.channels).forEach(function (id) {
    var c = s.channels[id];
    c.lines = linesOf(c);
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
    if (m.permalink) {
      c.link = m.permalink;
    }
    if (m.to_owner) {
      return;
    }
    byId[m.id] = m;
    input.push({ id: m.id, channel: m.channel, author: m.author, time: m.time, text: m.text,
      thread_id: m.thread_id, by_owner: m.by_owner, bot: m.bot });
  });
  if (input.length > 0) {
    var reply = llm(builtin.defaultPrompt("label"), { input: { owner: w.owner, messages: input }, schema: SCHEMA, tier: "light" });
    var dropped = { lines: 0, ids: [] };
    reply.lines.forEach(function (line) { addLine(s, byId, line, dropped); });
    if (dropped.lines > 0) {
      // The ids come from the model: each cut, the first 20 named.
      var named = dropped.ids.slice(0, 20).map(function (id) { return cut(String(id), 80); });
      log("warning: " + plural(dropped.lines, "line", "lines") + " dropped for unknown ids or empty text: " +
        named.join(", ") + (dropped.ids.length > 20 ? ", …" : ""));
    }
    capLines(s);
  }
  compactDay(s);
  state.set("today", s);
} else if (!valid || s.day !== w.day) {
  // The window was skipped (Slack off by policy) before any day, or after
  // midnight: today's empty card, no state written.
  s = freshDay(w.day);
}

output.inbox({ key: "slack-today", title: "Slack today", blocks: blocksOf(s) });
```
