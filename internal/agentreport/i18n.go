package agentreport

import (
	"fmt"
	"strings"
	"time"
)

// Lang is the language the hints' sentences are written in: the assistant
// language (digest.language), English unless it is Russian.
type Lang int

const (
	English Lang = iota
	Russian
)

// LangOf maps a digest.language value ("Russian", "ru", "русский") to a Lang.
func LangOf(name string) Lang {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "russian", "ru", "русский":
		return Russian
	}
	return English
}

// msgs holds each sentence as {English, Russian} format strings with the
// same verbs in the same order.
var msgs = map[string][2]string{
	"h1.where.session": {"session %s", "сессии %s"},
	"h1.where.target":  {"target %s", "задаче %s"},
	"h1.label":         {"%s, %s", "%s, %s"},
	"h1.finding": {"%s ran %s in %s, %s in all; the runs after the first took %s",
		"%s запускался %s в %s, всего %s; повторные запуски заняли %s"},
	"h1.action": {"Run only the tests of the package you changed; run the full suite once before the PR.",
		"Запускай тесты только изменённого пакета, полный прогон — один раз перед PR."},

	"h2.label": {"%s, %s", "%s, %s"},
	"h2.finding": {"%s (read, search and git status/log/diff) took a median of %s each, likely permission prompts; allow rules would help (/fewer-permission-prompts)",
		"%s чтения, поиска и git status/log/diff заняли в медиане по %s — похоже, ждали разрешения; помогут allow-правила (/fewer-permission-prompts)"},
	"h2.action": {"These calls likely waited on permission prompts. Allow them in .claude/settings.json.",
		"Похоже, эти вызовы ждали разрешения. Разреши их в .claude/settings.json."},

	"h3.label": {"%s, %s", "%s, %s"},
	"h3.finding": {"Session %s ran %s one after another (%.1f at once on average); in parallel they could save up to %s",
		"Сессия %s запускала %s по очереди (в среднем %.1f одновременно); параллельно можно было сэкономить до %s"},
	"h3.action": {"Ask for independent subagents in one message so they run in parallel.",
		"Проси независимых субагентов одним сообщением — тогда они работают параллельно."},

	"h4.label": {"%s waiting, %d%% of %s active", "ждал тебя %s, %d%% из %s активного времени"},
	"h4.and":   {" and ", " и "},
	"h4.finding": {"Waiting for you took over %d%% of active time in %s, %s in all",
		"Ожидание тебя заняло больше %d%% активного времени в %s, всего %s"},
	"h4.action": {"Answer asks sooner: turn on ask notifications on the Mac or the phone, or let agents use Quick asks.",
		"Отвечай на вопросы агентов быстрее: включи уведомления об asks на Mac или телефоне, или разреши агентам Quick-вопросы."},

	"h5.label": {"%s in a row", "%s подряд"},
	"h5.finding": {"%s failed %s in a row in session %s, %s spent on the failed runs",
		"%s упал %s подряд в сессии %s, на неудачные запуски ушло %s"},
	"h5.action": {"The agent retried a failing command. Open the session and add the fix to the folder rules.",
		"Агент повторял падающую команду. Открой сессию и добавь исправление в правила папки."},

	"h6.cache":   {"a %d%% cache read share", "долей чтения из кэша %d%%"},
	"h6.and":     {" and ", " и "},
	"h6.finding": {"Session %s cost %s with %s; its context was expensive", "Сессия %s стоила %s при %s — контекст был дорогим"},
	"h6.action": {"Start a new session per task, or /clear between tasks; long sessions re-read their whole context.",
		"Начинай новую сессию на каждую задачу или делай /clear между задачами: длинная сессия перечитывает весь контекст."},

	"h7.label": {"%s on subagents", "%s на субагентах"},
	"h7.finding": {"Subagents on %s cost %s, %d%% of the period's %s; on %s they would cost about %s less",
		"Субагенты на %s стоили %s, %d%% из %s за период; на %s вышло бы примерно на %s дешевле"},
	"h7.action": {"Run subagents on a cheaper model (model: sonnet in the agent definition).",
		"Запускай субагентов на модели дешевле (model: sonnet в описании агента)."},
}

// f formats the message key in the language.
func (l Lang) f(key string, args ...any) string {
	m, ok := msgs[key]
	if !ok {
		panic("agentreport: no message " + key)
	}
	return fmt.Sprintf(m[l], args...)
}

// nouns holds each counted noun as English {one, many} and Russian {one,
// few, many} forms; the ".in" nouns are the Russian prepositional ("в 2
// сессиях") and are only used in Russian.
var nouns = map[string]struct {
	en [2]string
	ru [3]string
}{
	"run":        {[2]string{"run", "runs"}, [3]string{"запуск", "запуска", "запусков"}},
	"time":       {[2]string{"time", "times"}, [3]string{"раз", "раза", "раз"}},
	"call":       {[2]string{"call", "calls"}, [3]string{"вызов", "вызова", "вызовов"}},
	"subagent":   {[2]string{"subagent", "subagents"}, [3]string{"субагент", "субагента", "субагентов"}},
	"fgsubagent": {[2]string{"foreground subagent", "foreground subagents"}, [3]string{"субагент", "субагента", "субагентов"}},
	"failure":    {[2]string{"failure", "failures"}, [3]string{"ошибка", "ошибки", "ошибок"}},
	"compaction": {[2]string{"compaction", "compactions"}, [3]string{"компакция", "компакции", "компакций"}},
	"session.in": {[2]string{"session", "sessions"}, [3]string{"сессии", "сессиях", "сессиях"}},
	"task.in":    {[2]string{"task", "tasks"}, [3]string{"задаче", "задачах", "задачах"}},
}

// count renders "4 runs" / "4 запуска".
func (l Lang) count(n int, noun string) string {
	f, ok := nouns[noun]
	if !ok {
		panic("agentreport: no noun " + noun)
	}
	if l == English {
		if n == 1 {
			return "1 " + f.en[0]
		}
		return fmt.Sprintf("%d %s", n, f.en[1])
	}
	form := f.ru[2]
	switch m10, m100 := n%10, n%100; {
	case m10 == 1 && m100 != 11:
		form = f.ru[0]
	case m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14):
		form = f.ru[1]
	}
	if strings.HasSuffix(noun, ".in") && form == f.ru[1] {
		// The prepositional has one plural form ("в 3 сессиях").
		form = f.ru[2]
	}
	return fmt.Sprintf("%d %s", n, form)
}

// dur renders ms as "2h 10m" / "2 ч 10 мин", "7m 10s" / "7 мин 10 с" or "45s" / "45 с".
func (l Lang) dur(ms int64) string {
	if l == English {
		return fmtDur(ms)
	}
	d := time.Duration(ms) * time.Millisecond
	h, m, s := int(d.Hours()), int(d.Minutes())%60, int(d.Seconds())%60
	switch {
	case h > 0:
		return fmt.Sprintf("%d ч %d мин", h, m)
	case m > 0:
		return fmt.Sprintf("%d мин %d с", m, s)
	}
	return fmt.Sprintf("%d с", s)
}

// sec renders ms under a minute with one decimal ("7.5s" / "7,5 с"), else as dur.
func (l Lang) sec(ms int64) string {
	if l == English {
		return fmtSec(ms)
	}
	if ms < time.Minute.Milliseconds() {
		return strings.Replace(fmt.Sprintf("%.1f с", float64(ms)/1000), ".", ",", 1)
	}
	return l.dur(ms)
}
