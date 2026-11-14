package coach

import (
	"fmt"
	"strings"

	"watchtower/internal/agentreport"
	"watchtower/internal/db"
)

// briefMsgs holds each sentence of a session brief as {English, Russian}.
// A brief is built from the proposal alone — its title, why, text and
// evidence — never from a path, a setting or any other configuration.
var briefMsgs = map[string][2]string{
	"title":        {"Coach #%d: %s", "Коуч #%d: %s"},
	"title.revert": {"Revert coach #%d: %s", "Откат коуча #%d: %s"},
	"intro": {"This session carries out coach proposal #%d, which the owner accepted in Watchtower.",
		"Эта сессия выполняет предложение коуча #%d, которое владелец принял в Watchtower."},
	"what":     {"What to change:", "Что изменить:"},
	"replace":  {"Make %s read exactly as below (the whole file):", "Сделай так, чтобы %s был ровно таким (весь файл):"},
	"measured": {"Measured:", "Замеры:"},
	"measured.saving_tokens": {"Expected saving: ~%s tokens per session start",
		"Ожидаемая экономия: ~%s токенов на старте каждой сессии"},
	"why": {"Why: %s", "Зачем: %s"},
	"saving.start_tokens": {"Expected saving: a smaller start context for every session — the sizes above are what goes.",
		"Ожидаемая экономия: меньше стартовый контекст каждой сессии — уходит то, что измерено выше."},
	"saving.other": {"Expected effect: the %s metric goes down; Watchtower measures it after the change.",
		"Ожидаемый эффект: метрика %s снижается; Watchtower измерит её после изменения."},
	"repo.rules": {"Work in your own worktree, run the project's pre-PR review, then open a PR — do not merge it: the owner merges.",
		"Работай в своём worktree, прогони pre-PR ревью проекта, затем открой PR — не мержи его: мержит владелец."},
	"restructure.repo_claude_md": {"Slim CLAUDE.md: move its largest `## ` sections out into separate documents of the repository and leave a one-line pointer to each in CLAUDE.md. Keep every rule; only where it lives changes.",
		"Сократи CLAUDE.md: вынеси самые большие разделы `## ` в отдельные документы репозитория и оставь в CLAUDE.md по строке-ссылке на каждый. Ни одно правило не теряется — меняется только место."},
	"restructure.repo": {"Restructure %s as the title says, keeping every rule it holds.",
		"Перестрой %s, как сказано в заголовке, не теряя ни одного правила."},
	"memory.what": {"Slim your project's auto-memory index, MEMORY.md: pick the lines no session needs at the start any more, move them into an archive memory file and leave one pointer line to that archive in MEMORY.md.",
		"Сократи индекс авто-памяти проекта, MEMORY.md: выбери строки, которые сессиям больше не нужны на старте, перенеси их в архивный файл памяти и оставь в MEMORY.md одну строку-ссылку на этот архив."},
	"memory.rules": {"Show the owner the diff with ask_owner (kind review) before writing; write only after the owner approves, and write no backup files into the memory folder — Watchtower keeps the old index. There is no PR: the memory is not in a repository.",
		"Перед записью покажи владельцу дифф через ask_owner (kind review) и пиши только после его одобрения. Не пиши резервных копий в папку памяти — Watchtower хранит старый индекс сам. PR не нужен: память не в репозитории."},
	"revert.what": {"The change of coach proposal #%d was merged in PR #%d, and the owner wants it undone.",
		"Изменение предложения коуча #%d смержено в PR #%d, и владелец хочет его откатить."},
	"revert.change": {"The change: %s", "Изменение: %s"},
	"revert.rules": {"Work in your own worktree on a new branch, revert that change, run the project's pre-PR review, then open a revert PR — do not merge it: the owner merges.",
		"Работай в своём worktree на новой ветке, откати это изменение, прогони pre-PR ревью проекта, затем открой revert PR — не мержи его: мержит владелец."},
}

func briefMsg(lang agentreport.Lang, key string, args ...any) string {
	m := briefMsgs[key]
	f := m[0]
	if lang == agentreport.Russian {
		f = m[1]
	}
	if len(args) == 0 {
		return f
	}
	return fmt.Sprintf(f, args...)
}

// Brief is the title and the opening prompt of the workbench session that
// carries out p, a repository or memory proposal (IsSessionDestination), in
// lang: what to change (the after-text, or for a restructure the instruction
// and the measured sizes), why and the expected saving, then the rules — for
// a repository change its own worktree, the project's pre-PR review and a PR
// it does not merge; for the memory index the owner's review of the diff
// through ask_owner and no backup files.
func Brief(p db.CoachProposal, lang agentreport.Lang) (title, prompt string) {
	var b strings.Builder
	line := func(s string) { b.WriteString(s + "\n") }
	line(briefMsg(lang, "intro", p.ID))
	line("")
	line(briefMsg(lang, "what"))
	switch {
	case p.Destination == DestMemoryIndex:
		line(briefMsg(lang, "memory.what"))
	case p.Kind == "restructure":
		if p.Destination == DestRepoClaudeMD {
			line(briefMsg(lang, "restructure.repo_claude_md"))
		} else {
			rel, _ := RepoRelPath(p.Destination, p.Skill)
			line(briefMsg(lang, "restructure.repo", rel))
		}
	default:
		rel, _ := RepoRelPath(p.Destination, p.Skill)
		line(briefMsg(lang, "replace", rel))
		line("```")
		b.WriteString(p.AfterText)
		if !strings.HasSuffix(p.AfterText, "\n") {
			line("")
		}
		line("```")
	}
	if len(p.Evidence) > 0 {
		line("")
		line(briefMsg(lang, "measured"))
		for _, e := range p.Evidence {
			if e.Kind == "saving_tokens" {
				line("- " + briefMsg(lang, "measured.saving_tokens", e.Ref))
				continue
			}
			line("- " + e.Ref)
		}
	}
	line("")
	line(briefMsg(lang, "why", p.Why))
	if p.Metric == "start_tokens" {
		line(briefMsg(lang, "saving.start_tokens"))
	} else {
		line(briefMsg(lang, "saving.other", p.Metric))
	}
	line("")
	if p.Destination == DestMemoryIndex {
		line(briefMsg(lang, "memory.rules"))
	} else {
		line(briefMsg(lang, "repo.rules"))
	}
	return briefMsg(lang, "title", p.ID, p.Title), b.String()
}

// RevertBrief is the title and prompt of the session that reverts p, a
// repository change merged in pull request pr: a revert PR
// from its own worktree, reviewed, not merged.
func RevertBrief(p db.CoachProposal, pr int64, lang agentreport.Lang) (title, prompt string) {
	var b strings.Builder
	b.WriteString(briefMsg(lang, "revert.what", p.ID, pr) + "\n")
	b.WriteString(briefMsg(lang, "revert.change", p.Title) + "\n\n")
	b.WriteString(briefMsg(lang, "revert.rules") + "\n")
	return briefMsg(lang, "title.revert", p.ID, p.Title), b.String()
}
