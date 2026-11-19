---
name: Разбор новых ишью Linear
trigger:
  schedule: "0 * * * *"
missed: run_once
concurrency: 1
permissions:
  - tool:list_linear_issues
  - tool:get_linear_issue
  - llm:strong
  - ask:owner
outputs: [inbox, report]
budget: { tokens: 200000, minutes: 15 }
---
Каждый час берёт ишью Linear за последние 7 дней, которые ещё не разбирала,
не больше 15 за запуск, остальные — в следующий час. Разобранные помнит по ключу,
а не по времени: ишью, которая пришла с опозданием синка, всё равно будет разобрана.
Сильная модель определяет тип
(Баг, Доработка, Новая фича, Дубликат, Тех. долг), проходит сценарий типа и даёт
вердикт «нужно» / «не нужно» / «под вопросом», класть ли в Backlog, резюме, разбор,
сомнения и готовый текст комментария для Linear. По каждой ишью — сообщение в Inbox,
в конце — один вопрос по спорным ишью, отчёт на карточке. В Linear ничего не пишет.

```js
const MAX = 15;
const WINDOW_DAYS = 7;
const now = Date.now();
const windowStart = new Date(now - WINDOW_DAYS * 24 * 3600 * 1000).toISOString();

function rows(r) {
  if (!r) return [];
  if (Array.isArray(r)) return r;
  return r.issues || r.items || r.results || [];
}
function keyOf(i) { return i.key || i.identifier || i.id; }
function createdOf(i) { return i.created_at || i.createdAt || i.created || ""; }
function clip(s, n) { s = s == null ? "" : String(s); return s.length > n ? s.slice(0, n) + "…" : s; }

// Разобранные ишью: ключ → когда создана. Не курсор по времени: синк Linear
// приносит ишью с опозданием, и курсор «с прошлого запуска» её бы пропустил.
const triaged = state.get("triaged") || {};
Object.keys(triaged).forEach(function (k) {
  if (Date.parse(triaged[k]) < Date.parse(windowStart)) delete triaged[k];
});

// Неразобранные ишью окна, старые первыми.
const fresh = rows(tool("list_linear_issues", { created_after: windowStart, limit: 200 }))
  .filter(function (i) { return !triaged[keyOf(i)]; })
  .sort(function (a, b) { return Date.parse(createdOf(a)) - Date.parse(createdOf(b)); });
const batch = fresh.slice(0, MAX);
const left = fresh.length - batch.length;

if (batch.length === 0) {
  log("Неразобранных ишью за " + WINDOW_DAYS + " дн. нет (разобрано в окне: " + Object.keys(triaged).length + ")");
  state.set("triaged", triaged);
} else {
  // До 200 последних ишью для поиска дубликатов — коротко.
  const recent = rows(tool("list_linear_issues", { limit: 200 })).map(function (i) {
    return { key: keyOf(i), title: i.title, state: i.state || i.state_name, description: clip(i.description, 200) };
  });

  // Полный текст каждой ишью.
  const full = batch.map(function (i) {
    let d = i;
    try { d = tool("get_linear_issue", { key: keyOf(i) }) || i; } catch (e) { log("Не удалось открыть " + keyOf(i)); }
    return {
      key: keyOf(i),
      title: d.title || i.title,
      state: d.state || i.state,
      team: d.team || i.team,
      created: createdOf(i),
      url: d.url || i.url,
      description: clip(d.description || i.description, 6000),
      comments: (d.comments || []).slice(0, 10).map(function (c) { return { author: c.author || c.user, body: clip(c.body, 800) }; })
    };
  });

  const PROMPT = [
    "Ты разбираешь новые ишью Linear для владельца продукта. Для каждой ишью из input.issues определи тип и пройди сценарий этого типа:",
    "- Баг: настоящий баг или особенность функционала; блокирует ли сценарий или можно обойти; насколько критична часть продукта.",
    "- Доработка: нужно ли с точки зрения ценностей; насколько просто; какая польза; есть ли обходные пути.",
    "- Новая фича: через призму ценностей; как ложится в концепцию; насколько масштабное изменение.",
    "- Дубликат: найди в input.recent (или среди других ишью в input.issues), какую ишью она повторяет, и укажи её ключ в duplicate_of.",
    "- Тех. долг: насколько мешает; чем рискуем, если не делать; сколько стоит.",
    "Ценности продукта пока не заданы: оценивай по здравому смыслу и обязательно напиши об этом в сомнениях.",
    "Для каждой ишью дай: тип, вердикт («нужно» / «не нужно» / «под вопросом»), класть ли в Backlog, резюме в 1–2 предложения, разбор по пунктам сценария, сомнения и готовый текст комментария для Linear (по-русски, вежливо, по делу).",
    "Для ишью с вердиктом «под вопросом» или «не нужно» дай рекомендацию: «В Backlog», «Не брать» или «Доработать описание». Пиши по-русски."
  ].join("\n");

  const SCHEMA = {
    type: "object",
    properties: {
      items: {
        type: "array",
        items: {
          type: "object",
          properties: {
            key: { type: "string" },
            type: { type: "string", enum: ["Баг", "Доработка", "Новая фича", "Дубликат", "Тех. долг"] },
            verdict: { type: "string", enum: ["нужно", "не нужно", "под вопросом"] },
            backlog: { type: "boolean" },
            duplicate_of: { type: "string" },
            summary: { type: "string" },
            analysis: { type: "string" },
            doubts: { type: "string" },
            comment: { type: "string" },
            recommendation: { type: "string", enum: ["В Backlog", "Не брать", "Доработать описание", ""] }
          },
          required: ["key", "type", "verdict", "backlog", "summary", "analysis", "doubts", "comment"]
        }
      }
    },
    required: ["items"]
  };

  // Пачками по 5, чтобы уложиться в бюджет токенов.
  let results = [];
  for (let s = 0; s < full.length; s += 5) {
    const part = full.slice(s, s + 5);
    const r = llm(PROMPT, { input: { issues: part, recent: recent }, schema: SCHEMA, tier: "strong" });
    results = results.concat((r && r.items) || []);
  }
  const byKey = {};
  results.forEach(function (r) { byKey[r.key] = r; });

  const disputed = [];
  full.forEach(function (i) {
    const r = byKey[i.key];
    if (!r) { log("Модель не вернула разбор для " + i.key); return; }
    const isDisputed = r.verdict === "под вопросом" || r.verdict === "не нужно";
    const urgent = r.type === "Баг" || isDisputed;
    if (isDisputed) disputed.push({ issue: i, r: r });
    const body = [
      (isDisputed ? "**Нужно ваше решение.**\n" : "") +
      "**" + i.key + "** — " + (i.title || "") + (i.url ? "\n" + i.url : ""),
      "**Тип:** " + r.type + (r.duplicate_of ? " (повторяет " + r.duplicate_of + ")" : ""),
      "**Вердикт:** " + r.verdict + " · **В Backlog:** " + (r.backlog ? "да" : "нет") +
        (r.recommendation ? " · **Рекомендация:** " + r.recommendation : ""),
      "**Резюме:** " + r.summary,
      "**Разбор:**\n" + r.analysis,
      "**Сомнения:**\n" + r.doubts,
      "**Комментарий для Linear:**\n> " + String(r.comment).split("\n").join("\n> ")
    ].join("\n\n");
    output.inbox({
      title: clip((isDisputed ? "[Нужно решение] " : "") + i.key + " · " + r.type + " · " + r.verdict + " — " + (i.title || ""), 200),
      body: body,
      priority: urgent ? "high" : "medium"
    });
  });

  // Один общий вопрос по спорным ишью.
  const decisions = {};
  if (disputed.length > 0) {
    const answer = ask({
      kind: "question",
      title: "Решения по спорным ишью Linear (" + disputed.length + ")",
      summary: "По каждой ишью — что делать. Рекомендация модели отмечена.",
      questions: disputed.slice(0, 4).map(function (d) {
        const rec = d.r.recommendation || (d.r.verdict === "не нужно" ? "Не брать" : "Доработать описание");
        return {
          id: d.issue.key,
          question: clip(d.issue.key + " — " + (d.issue.title || "") + " (" + d.r.type + ", " + d.r.verdict + ")", 200),
          multi: false,
          options: ["В Backlog", "Не брать", "Доработать описание"].map(function (o) {
            return { label: o, description: o === rec ? "Рекомендация модели: " + clip(d.r.summary, 120) : "", recommended: o === rec };
          })
        };
      })
    });
    log("Ответ владельца: " + JSON.stringify(answer));
    const a = (answer && (answer.answers || answer)) || {};
    disputed.forEach(function (d) {
      const v = a[d.issue.key];
      decisions[d.issue.key] = v == null ? "" : (Array.isArray(v) ? v.join(", ") : (v.label || String(v)));
    });
  }

  const lines = full.map(function (i) {
    const r = byKey[i.key];
    if (!r) return "- " + i.key + " — разбор не получен";
    return "- **" + i.key + "** · " + r.type + " · " + r.verdict + " · Backlog: " + (r.backlog ? "да" : "нет") +
      (decisions[i.key] ? " · **Ваше решение:** " + decisions[i.key] : "") + " — " + clip(r.summary, 200);
  });
  if (left > 0) lines.push("\nЕщё " + left + " ишью — в следующий час.");
  output.report({ title: "Разбор ишью Linear: " + full.length, body: lines.join("\n") });

  // Разобранными считаются ишью, по которым модель вернула разбор; остальные
  // попробуем в следующий час. Упавший прогон state не сохраняет — тоже повтор.
  full.forEach(function (i) {
    if (byKey[i.key]) triaged[i.key] = i.created || new Date(now).toISOString();
  });
  state.set("triaged", triaged);
}
```
