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
	"h1.and":           {" and ", " и "},
	"h1.finding": {"%s ran %d+ times in %s, %s in all; the most: %s in %s, %s; the runs after the first took %s",
		"%s запускался %d+ раз в %s, всего %s; больше всего — %s в %s, %s; повторные запуски заняли %s"},
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

	"h6.cache": {"a %d%% cache read share", "доле чтения из кэша %d%%"},
	"h6.and":   {" and ", " и "},
	"h6.finding": {"%s had expensive context, %s in all; the most: session %s cost %s with %s",
		"%s с дорогим контекстом, всего %s; больше всего — сессия %s стоила %s при %s"},
	"h6.action": {"Start a new session per task, or /clear between tasks; long sessions re-read their whole context.",
		"Начинай новую сессию на каждую задачу или делай /clear между задачами: длинная сессия перечитывает весь контекст."},

	"h7.label": {"%s on subagents", "%s на субагентах"},
	"h7.finding": {"Subagents on %s cost %s, %d%% of the period's %s; on %s they would cost about %s less",
		"Субагенты на %s стоили %s, %d%% из %s за период; на %s вышло бы примерно на %s дешевле"},
	"h7.action": {"Run subagents on a cheaper model (model: sonnet in the agent definition).",
		"Запускай субагентов на модели дешевле (model: sonnet в описании агента)."},

	"c1.finding": {"CLAUDE.md and rules take %d%% of every session start (%s); %s across the period's starts",
		"CLAUDE.md и правила занимают %d%% каждого старта сессии (%s); %s на всех стартах за период"},
	"c1.sub": {", and %d%% of a subagent's start", ", а у субагента — %d%% старта"},
	"c1.action": {"Move feature notes out of CLAUDE.md into docs the agent reads on demand; keep only the rules every task needs.",
		"Вынеси заметки по фичам из CLAUDE.md в документы, которые агент читает по необходимости; оставь только правила для каждой задачи."},

	"c2.label": {"%s added", "добавил %s"},
	"c2.finding": {"%s added %s to the context over %s, %d%% of its growth: %s",
		"%s добавил в контекст %s за %s — %d%% его роста: %s"},
	"c2.action.bash": {"Trim the output: pipe it through head or grep, or add a PostToolUse hook that shortens it.",
		"Сократи вывод: пропусти его через head или grep или добавь PostToolUse-хук, который его укорачивает."},
	"c2.action.read": {"Read the file with offset/limit, only the range you need.",
		"Читай файл с offset/limit — только нужный диапазон."},
	"c2.action.other": {"Ask for a smaller result, or move the sweep into a subagent so its output stays out of the main context.",
		"Запрашивай результат поменьше или вынеси перебор в субагента, чтобы его вывод не попадал в основной контекст."},

	"c3.label": {"%s of repeats", "повторы на %s"},
	"c3.finding": {"Re-reads of %s (%d+ times in one session) added %s; the most: %s, read %s in session %s",
		"Повторные чтения %s (%d+ раз в одной сессии) добавили %s; больше всего — %s, прочитан %s в сессии %s"},
	"c3.action": {"Read the file once and keep notes, or read only the range you need.",
		"Прочитай файл один раз и запиши заметки или читай только нужный диапазон."},

	"s1.label": {"%s a session", "%s за сессию"},
	"s1.finding": {"%d of %s %s; listing them took %s in %s",
		"%d из %s %s; их описания заняли %s в %s"},
	"s1.action": {"Disable or remove them, or rewrite the description of the ones that should trigger.",
		"Отключи или удали их либо перепиши описание тех, что должны срабатывать."},

	"t1.finding": {"%s: %s, mostly from %s, in %s; the failed calls took %s",
		"%s: %s, чаще всего у %s, в %s; неудачные вызовы заняли %s"},
	"t1.class.stale_read":       {"Edits of a file changed since it was read", "Правки файла, изменённого после чтения"},
	"t1.class.isolation_block":  {"Writes outside the session's worktree were blocked", "Запись вне worktree сессии заблокирована"},
	"t1.class.unknown_agent":    {"Subagents of an unknown type", "Субагенты неизвестного типа"},
	"t1.class.no_such_tool":     {"Calls of a tool that does not exist", "Вызовы несуществующего инструмента"},
	"t1.class.input_invalid":    {"Tool calls with invalid arguments", "Вызовы инструментов с неверными аргументами"},
	"t1.class.too_large":        {"Files too large to read whole", "Файлы слишком большие для чтения целиком"},
	"t1.class.edit_no_match":    {"Edit found no match for old_string", "Edit не нашёл old_string"},
	"t1.class.edit_multi_match": {"Edit found several matches for old_string", "Edit нашёл несколько совпадений old_string"},
	"t1.class.sleep_blocked":    {"Blocked sleep commands", "Заблокированные команды sleep"},
	"t1.class.agent_limit":      {"Subagents over the limit of concurrent ones", "Субагенты сверх лимита одновременных"},
	"t1.action.isolation": {"Add the rule to the folder's workflow so agents stay in their worktree.",
		"Добавь правило в workflow папки, чтобы агенты оставались в своём worktree."},
	"t1.action.definition": {"Fix the skill or agent definition that names it.",
		"Исправь скилл или описание агента, которые его называют."},
	"t1.action.input": {"The tool's arguments are wrong — check the skill that calls it.",
		"Аргументы инструмента неверны — проверь скилл, который его вызывает."},
	"t1.action.large": {"Read large files with offset/limit.", "Читай большие файлы с offset/limit."},
	"t1.action.edit": {"Re-read before editing; give more context in old_string.",
		"Перечитывай файл перед правкой; давай больше контекста в old_string."},
	"t1.action.sleep": {"Use background tasks and notifications instead of sleep.",
		"Используй фоновые задачи и уведомления вместо sleep."},
	"t1.action.agents": {"Start fewer subagents at once.", "Запускай меньше субагентов одновременно."},

	"t2.finding": {"Auto mode or a permission rule blocked %s of %s, %s in all: %s",
		"Auto mode или правило разрешений заблокировали %s %s, всего %s: %s"},
	"t2.action": {"Allow them in .claude/settings.json.", "Разреши их в .claude/settings.json."},
	"t2.action.review": {"Review the blocked commands: change how the agent runs them, or allow the safe ones in .claude/settings.json yourself.",
		"Проверь заблокированные команды: измени то, как агент их запускает, или сам разреши безопасные в .claude/settings.json."},

	"t3.label": {"%s, %s stopped", "%s, остановлено %s"},
	"t3.finding": {"You stopped or rejected the agent %d+ times in %s (%s in all); the stopped work took %s",
		"Ты останавливал или отклонял агента %d+ раз в %s (всего %s); остановленная работа заняла %s"},
	"t3.action": {"Write the expectation into the folder rules or agree a plan before the agent starts.",
		"Запиши ожидание в правила папки или согласуй план до старта агента."},
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
	"session":    {[2]string{"session", "sessions"}, [3]string{"сессия", "сессии", "сессий"}},
	"session.in": {[2]string{"session", "sessions"}, [3]string{"сессии", "сессиях", "сессиях"}},
	"task.in":    {[2]string{"task", "tasks"}, [3]string{"задаче", "задачах", "задачах"}},
	"file.of":    {[2]string{"file", "files"}, [3]string{"файла", "файлов", "файлов"}},
	"skill.of":   {[2]string{"listed skill", "listed skills"}, [3]string{"навыка в списке", "навыков в списке", "навыков в списке"}},
	"never.used": {[2]string{"was never used", "were never used"}, [3]string{"ни разу не использовался", "ни разу не использовались", "ни разу не использовались"}},
	"token":      {[2]string{"token", "tokens"}, [3]string{"токен", "токена", "токенов"}},
	"command.of": {[2]string{"command", "commands"}, [3]string{"команды", "команд", "команд"}},
	"denial":     {[2]string{"denial", "denials"}, [3]string{"отказ", "отказа", "отказов"}},
}

// count renders "4 runs" / "4 запуска".
func (l Lang) count(n int, noun string) string { return fmt.Sprintf("%d %s", n, l.form(n, noun)) }

// form is the noun's form for n, without the number ("runs" / "запуска").
func (l Lang) form(n int, noun string) string {
	f, ok := nouns[noun]
	if !ok {
		panic("agentreport: no noun " + noun)
	}
	if l == English {
		if n == 1 {
			return f.en[0]
		}
		return f.en[1]
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
	return form
}

// tok renders a token count compactly: "9500 tokens" / "9500 токенов" under
// ten thousand, "12.3k tokens" / "12,3 тыс. токенов" under a million, else
// "44.4M tokens" / "44,4 млн токенов".
func (l Lang) tok(n int64) string {
	if n < 10_000 {
		return l.count(int(n), "token")
	}
	v, unit := float64(n)/1e3, [2]string{"k", " тыс."}
	if n >= 999_950 { // would round to 1000.0k
		v, unit = float64(n)/1e6, [2]string{"M", " млн"}
	}
	if l == English {
		return fmt.Sprintf("%.1f%s tokens", v, unit[0])
	}
	return strings.Replace(fmt.Sprintf("%.1f%s токенов", v, unit[1]), ".", ",", 1)
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
