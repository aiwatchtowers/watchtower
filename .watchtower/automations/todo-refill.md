---
name: TO DO на неделю вперёд
trigger:
  schedule: "0 9 * * *"
missed: run_once
concurrency: 1
permissions:
  - session:start
  - shell:"cat /tmp/watchtower-todo-refill.json"
  - ask:owner
outputs: [report]
budget: { tokens: 20000, minutes: 15 }
---
Каждый день в 9:00 агент смотрит колонку TO DO на борде воркбенча watchtower и
оценивает, хватает ли там работы минимум на неделю. Если не хватает — подбирает
задачи из Backlog по приоритету и размеру. Вы получаете вопрос с кнопками
«Взять в TO DO» / «Не брать» (с рекомендацией). Что вы одобрили — переносит второй
агент. Без вашего одобрения в TO DO ничего не попадает.

```js
const FILE = "/tmp/watchtower-todo-refill.json";
const runId = String(trigger.run_id);

// 1. Агент оценивает TO DO и подбирает кандидатов из Backlog.
const s1 = session({
  title: "TO DO: проверка запаса на неделю",
  prompt: [
    "Посмотри борду этого воркбенча (workbench_board).",
    "Оцени по описанию каждой задачи в колонке TO DO её размер в рабочих днях (S = до 1 дня, M = 2–3 дня, L = 4–5 дней) и посчитай, хватает ли в TO DO работы минимум на неделю (5 рабочих дней).",
    "Если не хватает — подбери из Backlog задачи, чтобы добрать до недели: сначала по приоритету (high, medium, low), при равном приоритете — так, чтобы суммарно получилась примерно неделя. Не больше 8 задач.",
    "НИЧЕГО на борде не меняй и не создавай asks: решение примет владелец.",
    "Запиши результат в файл " + FILE + " строго в формате JSON:",
    "{\"run_id\": \"" + runId + "\", \"todo_days\": <число>, \"todo\": [{\"id\": <id>, \"title\": \"...\", \"size\": \"S|M|L\", \"days\": <число>}], \"enough\": true|false, \"candidates\": [{\"id\": <id цели>, \"title\": \"...\", \"priority\": \"high|medium|low\", \"size\": \"S|M|L\", \"days\": <число>, \"why\": \"почему её стоит взять, одна фраза\", \"recommend\": true|false}]}",
    "Используй только реальные id с борды. Пиши по-русски. Затем вызови finish_session."
  ].join("\n")
});

let plan = null;
if (s1.status === "dry_run") {
  log("Пробный прогон: сессия агента не запускалась");
} else if (s1.status !== "finished") {
  throw new Error("Сессия оценки закончилась со статусом " + s1.status + ": " + (s1.error || s1.summary || ""));
} else {
  const res = shell("cat " + FILE);
  if (res.exit_code !== 0) throw new Error("Не удалось прочитать " + FILE + ": " + (res.stderr || ""));
  plan = JSON.parse(res.stdout);
  if (String(plan.run_id) !== runId) throw new Error("Файл " + FILE + " не от этого запуска");
}

if (!plan) {
  output.report({ title: "TO DO: пробный прогон", body: "Агент в пробном прогоне не запускается — оценки нет." });
} else if (plan.enough || !(plan.candidates || []).length) {
  output.report({
    title: "TO DO: работы хватает (~" + plan.todo_days + " дн.)",
    body: (plan.todo || []).map(function (t) { return "- #" + t.id + " " + t.title + " · " + t.size + " (~" + t.days + " дн.)"; }).join("\n") || "TO DO пуст, а в Backlog нечего взять."
  });
} else {
  // 2. Вопрос с кнопками, по 4 задачи на карточку.
  const cands = plan.candidates.slice(0, 8);
  const approved = [];
  for (let k = 0; k < cands.length; k += 4) {
    const part = cands.slice(k, k + 4);
    const answer = ask({
      kind: "question",
      title: "Добрать TO DO до недели (" + (k + 1) + "–" + (k + part.length) + " из " + cands.length + ")",
      summary: "В TO DO сейчас работы примерно на " + plan.todo_days + " дн. из 5. Кандидаты из Backlog — отмечена рекомендация.",
      questions: part.map(function (c) {
        return {
          id: String(c.id),
          question: ("#" + c.id + " " + c.title + " · " + c.priority + " · " + c.size + " (~" + c.days + " дн.)").slice(0, 200),
          multi: false,
          options: [
            { label: "Взять в TO DO", description: (c.why || "").slice(0, 100), recommended: !!c.recommend },
            { label: "Не брать", description: "Оставить в Backlog", recommended: !c.recommend }
          ]
        };
      })
    });
    log("Ответ: " + JSON.stringify(answer));
    const a = (answer && (answer.answers || answer)) || {};
    part.forEach(function (c) {
      let v = a[String(c.id)];
      if (Array.isArray(v)) v = v[0];
      if (v && typeof v === "object") v = v.label;
      if (String(v || "").indexOf("Взять") === 0) approved.push(c);
    });
  }

  // 3. Агент переносит одобренное.
  let moved = "ничего не переносилось";
  if (approved.length) {
    const s2 = session({
      title: "TO DO: перенос одобренных задач",
      prompt: "Владелец одобрил перенос этих задач из Backlog в колонку TO DO: " +
        approved.map(function (c) { return "#" + c.id + " " + c.title; }).join("; ") +
        ". Перенеси на борде ровно их (update_target, колонка TO DO), больше ничего не меняй. Затем вызови finish_session."
    });
    moved = s2.status === "finished" ? (s2.summary || "перенесено") : ("перенос не удался: " + s2.status + " " + (s2.error || ""));
  }

  const lines = cands.map(function (c) {
    const ok = approved.indexOf(c) >= 0;
    return "- #" + c.id + " " + c.title + " · " + c.priority + " · " + c.size + " (~" + c.days + " дн.) — **" + (ok ? "Взять" : "Не брать") + "**";
  });
  output.report({
    title: "TO DO: было ~" + plan.todo_days + " дн., одобрено " + approved.length + " из " + cands.length,
    body: lines.join("\n") + "\n\n**Перенос:** " + moved
  });
}
```
