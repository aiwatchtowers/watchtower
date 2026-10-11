# Handoff: owner asks for the mobile project (2026-10-10, shipped 2026-10-11)

**For:** the mobile project (the phone app and its connection to the Mac).
**From:** owner asks v2, board #503 — spec `docs/superpowers/specs/2026-10-10-owner-asks-v2-design.md` Part 10, business spec `docs/superpowers/specs/2026-10-10-owner-asks-v2-business.md`. The repo-side notes are in `docs/features/workbench.md`, "Asks for other clients".

This repo ships the data and one read verb. How a phone reaches the Mac (push service, relay, iCloud, anything else) is the mobile project's choice. Answering from the phone is **not built yet**; it is designed below as the next step.

## Owner decision D3 — the level is stored, never computed on the phone

An ask's level (`quick` or `full`) is computed once, in Go, when the ask is filed, and stored in `owner_asks.level`. The agent can only force `full`. The Desktop, `list_asks`/`get_ask` and the listing below all read the stored column. **The phone never classifies an ask**: it reads `level` and shows it. One rule, everywhere the same answer.

- **Quick** — `kind question`, one single-choice question, 2–3 options (labels at most 40 runes, descriptions at most 100), or 0 options when Watchtower raised it from a terminal question (`origin chat`, free reply only).
- **Full** — everything else: reviews, manual checks, several questions, 4 options, long labels. Answered in the Mac's drawer.

## 1. Read (shipped) — `watchtower workbench asks --json`

```
watchtower workbench asks --json [--workbench N] [--open]
```

One JSON object on stdout. Every ask of every workbench (workbench id order, then each workbench's own order), or of workbench N only; `--open` keeps the open ones (otherwise `open`, `answered`, `delivered` and `withdrawn` are all listed).

Example (placeholder ids and names only):

```json
{
  "ok": true,
  "asks": [
    {
      "id": 101,
      "workbench_id": 3,
      "workbench_name": "acme-api",
      "session_id": 42,
      "session_title": "Payments refactor",
      "kind": "question",
      "level": "quick",
      "origin": "chat",
      "chat_asked_at": "2026-10-11T09:14:05.123Z",
      "status": "open",
      "created_at": "2026-10-11T09:24:07Z",
      "title": "Use snake_case or camelCase for the new keys?",
      "summary": "Use snake_case or camelCase for the new keys?\nAsked in the terminal; no answer for 10 min.",
      "questions": [
        {
          "id": "q1",
          "question": "Use snake_case or camelCase for the new keys?",
          "multi": false,
          "options": [
            {"label": "snake_case", "description": "", "recommended": true},
            {"label": "camelCase", "description": "", "recommended": false}
          ]
        }
      ]
    },
    {
      "id": 102,
      "workbench_id": 3,
      "workbench_name": "acme-api",
      "session_id": null,
      "session_title": "",
      "kind": "review",
      "level": "full",
      "origin": "agent",
      "chat_asked_at": "",
      "status": "open",
      "created_at": "2026-10-11T10:02:00Z",
      "title": "Review the payments plan",
      "summary": "Two open points in Part 3.",
      "doc_path": "docs/plans/payments.md"
    }
  ]
}
```

The stamps above only show the shape; read `created_at` and `chat_asked_at` as opaque strings and parse them with the formats the Mac writes (`chat_asked_at` uses the session state stamp layout, `created_at` the ask's own; both UTC).

**Fields** (the keys are fixed; the mobile companion decodes exactly these):

| Key | Meaning |
|---|---|
| `id`, `workbench_id`, `workbench_name` | The ask and its workbench. |
| `session_id`, `session_title` | The terminal session that filed it; `null` / `""` for an ask filed from an external terminal or whose session is gone. |
| `kind` | `question`, `review` or `check`. |
| `level` | `quick` or `full` — stored, never computed by the client (D3). |
| `origin`, `chat_asked_at` | `chat` when Watchtower raised the agent's terminal question itself, with the time it was asked in the terminal; `agent` and `""` otherwise. |
| `status` | `open`, `answered`, `delivered` or `withdrawn`. |
| `created_at`, `title`, `summary` | As filed. |
| `questions` | `kind question` only: `id`, `question`, `multi`, `options[{label, description, recommended}]`. Answers carry the question's own `id` (often `"1"` for an agent's ask, `"q1"` for one raised from chat). |
| `checklist_count` | `kind check` only: how many steps. |
| `doc_path` | `kind review` only: the reviewed file, relative to the workbench folder. |
| `payload_error` | Present only when the stored payload does not parse: that ask is listed without `questions`/`checklist_count`; the other asks are unaffected. |

Keys for another kind are omitted, not empty.

**Failures.** Any failure is `{"ok": false, "error": "..."}` with exit 0: a missing database, a database older than migration `00107` (it predates the ask levels — the Mac app upgrades it on launch), a broken config, an unknown workbench, `--workbench 0`. Only arguments the CLI cannot parse (no `--json`, an unknown flag, a positional argument) exit non-zero, with no JSON. The verb is read-only: it never creates or migrates the database and does not block writers.

## 2. What a push shows (contract)

- **Title:** `<workbench name> · ask #<id>`. **Body:** the ask's title; for `origin chat` add the suffix "· from chat, <N> min" (the age from `chat_asked_at`, whole minutes).
- **Quick:** one action per option, the recommended one(s) first, at most 3, plus **Reply** (a text-input action, one line).
- **Full:** no answer actions; one **Open** action, which shows the ask read-only on the phone. It is answered on the Mac.
- Suggested, not part of the spec's contract: push new `open` asks (a new `id`), and drop the notification of an ask that leaves `open` (answered on the Mac, withdrawn by the agent).

## 3. Answer (planned next step, not built)

Until this lands, an answer reaches the agent only from the Mac. The design, to be built when the mobile transport is chosen:

1. **A validated write verb** on the Mac: `watchtower workbench ask answer --id N --json <answer>`. It runs `asks.ValidateAnswer` against the stored kind and payload, accepts **Quick asks only**, and writes with the same guarded `UPDATE owner_asks … WHERE status = 'open'` the Desktop uses (`OwnerAskQueries.answer`), so an ask withdrawn or answered meanwhile is refused and nothing is written.
2. **Answer shape** (the Desktop's Quick answers, already in use): a tap is `{"answers": [{"id": "<question id>", "labels": ["<option label>"], "other": ""}], "checklist": [], "comments": [], "note": "", "verdict": ""}`; a Reply is the same with `"labels": []` and `"other": "<one line, trimmed, at most 500 runes>"`. A 0-option ask takes only a Reply. The canonical form (every key, sorted) is pinned by `internal/asks/testdata/answers/valid_question_quick.json` and `valid_question_reply.json`, which Go and Swift both read.
3. **Delivery to the agent:** the Desktop delivers an ask it sees turn `answered` without its own answer call, through the existing PROJ-12 path (the fixed `Ask #N answered …` line, auto-submitted under PROJ-12's rules: held at a permission prompt, only pasted over the owner's half-typed text). This needs a **PROJ-12 amendment approved by the owner** at that time; until then the next `workbench brief` of the session still lists the answer.

Nothing in the phone ever classifies an ask, types into a terminal, or writes the database directly.
