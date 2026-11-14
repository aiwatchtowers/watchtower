package coach

import (
	"fmt"

	"watchtower/internal/agentreport"
)

// importWhy is the reason of a proposal carried over from an instruction
// suggestion, in the owner's language (digest.language): n is the number of
// sessions the miner saw the line in.
func importWhy(lang string, n int) string {
	if agentreport.LangOf(lang) == agentreport.Russian {
		word := "сессиях"
		if n%10 == 1 && n%100 != 11 {
			word = "сессии"
		}
		return fmt.Sprintf("Ты говорил это в %d %s", n, word)
	}
	if n == 1 {
		return "You said this in 1 session"
	}
	return fmt.Sprintf("You said this in %d sessions", n)
}

// ctxTexts are the context proposer's titles and reasons (key ctx.*), in
// English and Russian; the fmt verbs take the names and numbers the
// proposer passes, never a config value.
var ctxTexts = map[string][2]string{
	"ctx.plugin.title":     {"Turn off the %s plugin", "Выключить плагин %s"},
	"ctx.server.title":     {"Remove the %s MCP server", "Убрать MCP-сервер %s"},
	"ctx.connectors.title": {"Turn off the claude.ai connectors", "Выключить коннекторы claude.ai"},
	"ctx.unused.why": {
		"It adds %d tokens to every session start and had 0 calls in Watchtower sessions (all workbenches) in %d days. It is turned off for every project, not only this workbench.",
		"Добавляет %d токенов к старту каждой сессии, а в сессиях Watchtower (во всех воркбенчах) за %d дней — 0 вызовов. Выключается для всех проектов, не только для этого воркбенча.",
	},
	"ctx.claudemd.title": {"Move the big sections out of CLAUDE.md", "Вынести большие разделы из CLAUDE.md"},
	"ctx.claudemd.why": {
		"CLAUDE.md is %.1f KB and loads into every session; %d section(s) of %d KB or more can move to notes the agent reads when it needs them.",
		"CLAUDE.md весит %.1f КБ и грузится в каждую сессию; %d раздел(а) от %d КБ можно вынести в заметки, которые агент читает по необходимости.",
	},
	"ctx.memory.title": {"Archive the stale lines of the memory index", "Убрать устаревшие строки из индекса памяти"},
	"ctx.memory.why": {
		"The memory index is %.1f KB and loads into every session; a session can move its stale lines into an archive file behind one pointer line, after you review the diff.",
		"Индекс памяти весит %.1f КБ и грузится в каждую сессию; сессия может перенести устаревшие строки в архивный файл за одной строкой-ссылкой — после того как ты посмотришь дифф.",
	},
}

// ctxText is the ctx.* text key in lang, formatted with args.
func ctxText(lang agentreport.Lang, key string, args ...any) string {
	t := ctxTexts[key]
	s := t[0]
	if lang == agentreport.Russian {
		s = t[1]
	}
	return fmt.Sprintf(s, args...)
}
