---
name: Разбор новых ишью GitHub
trigger:
  schedule: "0 * * * *"
missed: run_once
concurrency: 1
permissions:
  - shell:"gh issue list --state all --limit 200 --json number,title,body,state,createdAt,url,labels,author"
  - llm:strong
  - ask:owner
outputs: [inbox, report]
budget: { tokens: 200000, minutes: 15 }
---
Каждый час берёт ишью GitHub репозитория папки watchtower за последние 7 дней,
которые ещё не разбирала, не больше 15 за запуск, остальные — в следующий час.
Разобранные помнит по номеру, а не по времени.
Для поиска дубликатов смотрит до 200 последних ишью. Сильная модель определяет тип
(Баг, Доработка, Новая фича, Дубликат, Тех. долг), проходит сценарий типа и даёт
вердикт «нужно» / «не нужно» / «под вопросом», класть ли в Backlog, резюме, разбор,
сомнения и готовый текст комментария для GitHub. По каждой ишью — сообщение в Inbox,
в конце — один вопрос по спорным ишью, отчёт на карточке. В GitHub ничего не пишет.

```js
const CMD = "gh issue list --state all --limit 200 --json number,title,body,state,createdAt,url,labels,author";
const MAX = 15;
const WINDOW_DAYS = 7;
const now = Date.now();
const windowStart = new Date(now - WINDOW_DAYS * 24 * 3600 * 1000).toISOString();

function clip(s, n) { s = s == null ? "" : String(s); return s.length > n ? s.slice(0, n) + "…" : s; }
function keyOf(i) { return "#" + i.number; }

const res = shell(CMD);
let all = [];
if (trigger.dry_run && res.exit_code === undefined) {
  log("Пробный прогон: команда gh не запускалась, список ишью пуст");
} else if (res.exit_code !== 0) {
  throw new Error("gh issue list не сработал: " + clip(res.stderr, 500));
} else {
  all = JSON.parse(res.stdout || "[]");
}

// Разобранные ишью: номер → когда создана. Не курсор по времени: курсор
// «с прошлого запуска» теряет всё, что пришло между его чтением и записью.
let triaged = state.get("triaged");
if (!triaged) {
  // Переход со старого курсора: всё, что создано до него, уже видел прежний рецепт.
  triaged = {};
  const oldSince = state.get("since");
  if (oldSince) {
    all.forEach(function (i) {
      if (Date.parse(i.createdAt) < Date.parse(oldSince)) triaged[keyOf(i)] = i.createdAt;
    });
  }
}
Object.keys(triaged).forEach(function (k) {
  if (Date.parse(triaged[k]) < Date.parse(windowStart)) delete triaged[k];
});

// Неразобранные ишью окна, старые первыми.
const fresh = all
  .filter(function (i) { return Date.parse(i.createdAt) >= Date.parse(windowStart) && !triaged[keyOf(i)]; })
  .sort(function (a, b) { return Date.parse(a.createdAt) - Date.parse(b.createdAt); });
const batch = fresh.slice(0, MAX);
const left = fresh.length - batch.length;

if (batch.length === 0) {
  log("Неразобранных ишью за " + WINDOW_DAYS + " дн. нет (всего в списке " + all.length + ")");
  state.set("triaged", triaged);
} else {
  // До 200 последних ишью для поиска дубликатов — коротко.
  const recent = all.map(function (i) {
    return { key: keyOf(i), title: i.title, state: i.state, description: clip(i.body, 200) };
  });

  const full = batch.map(function (i) {
    return {
      key: keyOf(i),
      title: i.title,
      state: i.state,
      author: i.author && i.author.login,
      labels: (i.labels || []).map(function (l) { return l.name; }),
      created: i.createdAt,
      url: i.url,
      description: clip(i.body, 6000)
    };
  });

  const PROMPT = [
    "Ты разбираешь новые ишью GitHub для владельца продукта. Для каждой ишью из input.issues определи тип и пройди сценарий этого типа:",
    "- Баг: настоящий баг или особенность функционала; блокирует ли сценарий или можно обойти; насколько критична часть продукта.",
    "- Доработка: нужно ли с точки зрения ценностей; насколько просто; какая польза; есть ли обходные пути.",
    "- Новая фича: через призму ценностей; как ложится в концепцию; насколько масштабное изменение.",
    "- Дубликат: найди в input.recent (или среди других ишью в input.issues), какую ишью она повторяет, и укажи её номер (например #12) в duplicate_of.",
    "- Тех. долг: насколько мешает; чем рискуем, если не делать; сколько стоит.",
    "Ценности продукта пока не заданы: оценивай по здравому смыслу и обязательно напиши об этом в сомнениях.",
    "Для каждой ишью дай: тип, вердикт («нужно» / «не нужно» / «под вопросом»), класть ли в Backlog, резюме в 1–2 предложения, разбор по пунктам сценария, сомнения и готовый текст комментария для GitHub (по-русски, вежливо, по делу).",
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
      "**Комментарий для GitHub:**\n> " + String(r.comment).split("\n").join("\n> ")
    ].join("\n\n");
    output.inbox({
      title: clip((isDisputed ? "[Нужно решение] " : "") + "GitHub " + i.key + " · " + r.type + " · " + r.verdict + " — " + (i.title || ""), 200),
      body: body,
      priority: urgent ? "high" : "medium"
    });
  });

  // Один общий вопрос по спорным ишью.
  const decisions = {};
  if (disputed.length > 0) {
    const answer = ask({
      kind: "question",
      title: "Решения по спорным ишью GitHub (" + disputed.length + ")",
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
  output.report({ title: "Разбор ишью GitHub: " + full.length, body: lines.join("\n") });

  // Разобранными считаются ишью, по которым модель вернула разбор; остальные
  // попробуем в следующий час. Упавший прогон state не сохраняет — тоже повтор.
  full.forEach(function (i) {
    if (byKey[i.key]) triaged[i.key] = i.created;
  });
  state.set("triaged", triaged);
}
```
