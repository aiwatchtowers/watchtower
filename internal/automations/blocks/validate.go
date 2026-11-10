package blocks

import (
	"maps"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"

	"watchtower/internal/db"
)

// Validate turns the script's blocks value (goja-exported: []any of
// map[string]any, strings, int64/float64, bool, nil) into a canonical
// document, or refuses it with an *Error naming the path and the rule (or
// the error of opts.AllowKind unchanged). fn is the SDK call's name
// ("output.inbox").
func Validate(fn string, v any, opts Options) (Document, error) {
	list, ok := v.([]any)
	if !ok {
		return Document{}, errorf("%s(): blocks must be an array of blocks", fn)
	}
	if len(list) > MaxBlocks {
		return Document{}, errorf("%s(): blocks has %d blocks; the limit is %d", fn, len(list), MaxBlocks)
	}
	val := &validator{fn: fn, opts: opts, actions: opts.CardActions}
	d := Document{V: Version, Blocks: make([]Block, 0, len(list))}
	for i, raw := range list {
		b, err := val.block("blocks["+strconv.Itoa(i)+"]", raw)
		if err != nil {
			return Document{}, err
		}
		d.Blocks = append(d.Blocks, b)
	}
	if val.rows > MaxRows {
		return Document{}, errorf("%s(): the card has %d list and table rows; the limit is %d", fn, val.rows, MaxRows)
	}
	if val.actions > MaxActions {
		return Document{}, errorf("%s(): the card has %d actions; the limit is %d", fn, val.actions, MaxActions)
	}
	b, err := d.Canonical()
	if err != nil {
		return Document{}, errorf("%s(): blocks: %v", fn, err)
	}
	if len(b) > MaxBlocksBytes {
		return Document{}, errorf("%s(): blocks is %d bytes; the limit is %d", fn, len(b), MaxBlocksBytes)
	}
	return d, nil
}

// validator carries the call's name, options and the document-wide counts.
type validator struct {
	fn            string
	opts          Options
	rows, actions int
}

var blockKeys = map[string][]string{
	TypeHeading: {"text", "level"},
	TypeText:    {"markdown"},
	TypeList:    {"title", "rows", "empty"},
	TypeTable:   {"title", "columns", "rows"},
	TypePerson:  {"name", "role", "avatar", "lines", "link"},
	TypeMetrics: {"items"},
	TypeLink:    {"title", "url", "subtitle"},
	TypeActions: {"actions"},
}

func (v *validator) block(path string, raw any) (Block, error) {
	m, ok := raw.(map[string]any)
	if !ok {
		return Block{}, v.errf("%s must be an object {type, …}", path)
	}
	t, has := m["type"]
	typ, isString := t.(string)
	if !has || !isString {
		return Block{}, v.errf("%s: a block needs a type; the blocks are %s", path, strings.Join(blockTypes, ", "))
	}
	keys, known := blockKeys[typ]
	if !known {
		return Block{}, v.errf("%s: unknown block type %q; the blocks are %s", path, typ, strings.Join(blockTypes, ", "))
	}
	if err := v.knownKeys(path, m, append([]string{"type"}, keys...)); err != nil {
		return Block{}, err
	}
	b := Block{Type: typ}
	var err error
	switch typ {
	case TypeHeading:
		b.Heading, err = v.heading(path, m)
	case TypeText:
		b.Text, err = v.text(path, m)
	case TypeList:
		b.List, err = v.list(path, m)
	case TypeTable:
		b.Table, err = v.table(path, m)
	case TypePerson:
		b.Person, err = v.person(path, m)
	case TypeMetrics:
		b.Metrics, err = v.metrics(path, m)
	case TypeLink:
		b.Link, err = v.link(path, m)
	case TypeActions:
		b.Actions, err = v.actionsBlock(path, m)
	}
	return b, err
}

func (v *validator) heading(path string, m map[string]any) (*Heading, error) {
	h := &Heading{Level: 1}
	var err error
	if h.Text, err = v.reqString(path, m, "text", MaxHeadingChars); err != nil {
		return nil, err
	}
	if raw, has := m["level"]; has {
		n, isInt := raw.(int64)
		if !isInt || (n != 1 && n != 2) {
			return nil, v.errf("%s.level must be 1 or 2", path)
		}
		h.Level = int(n)
	}
	return h, nil
}

func (v *validator) text(path string, m map[string]any) (*Text, error) {
	s, ok := m["markdown"].(string)
	s = strings.TrimSpace(s)
	if !ok || s == "" {
		return nil, v.errf("%s.markdown must be a non-empty string", path)
	}
	if len(s) > MaxTextBytes {
		return nil, v.errf("%s.markdown is %d bytes; the limit is %d", path, len(s), MaxTextBytes)
	}
	return &Text{Markdown: s}, nil
}

func (v *validator) list(path string, m map[string]any) (*List, error) {
	l := &List{Empty: DefaultListEmpty}
	var err error
	if l.Title, err = v.optString(path, m, "title", MaxListTitleChars); err != nil {
		return nil, err
	}
	if _, has := m["empty"]; has {
		if l.Empty, err = v.reqString(path, m, "empty", MaxListEmptyChars); err != nil {
			return nil, err
		}
	}
	rows, err := v.array(path+".rows", m["rows"], 0, MaxListRows, "rows")
	if err != nil {
		return nil, err
	}
	v.rows += len(rows)
	l.Rows = make([]ListRow, 0, len(rows))
	for i, raw := range rows {
		r, err := v.listRow(path+".rows["+strconv.Itoa(i)+"]", raw)
		if err != nil {
			return nil, err
		}
		l.Rows = append(l.Rows, *r)
	}
	return l, nil
}

var rowKeys = []string{"title", "subtitle", "badge", "tone", "link", "actions", "ref"}

func (v *validator) listRow(path string, raw any) (*ListRow, error) {
	m, err := v.object(path, raw, rowKeys, "{title, subtitle?, badge?, tone?, link?, actions?, ref?}")
	if err != nil {
		return nil, err
	}
	r := &ListRow{Actions: []db.InboxAction{}}
	if r.Title, err = v.reqString(path, m, "title", MaxRowTitleChars); err != nil {
		return nil, err
	}
	if r.Subtitle, err = v.optString(path, m, "subtitle", MaxRowSubtitleChars); err != nil {
		return nil, err
	}
	if raw, has := m["badge"]; has {
		bm, err := v.object(path+".badge", raw, []string{"text", "tone"}, "{text, tone?}")
		if err != nil {
			return nil, err
		}
		r.Badge = &Badge{}
		if r.Badge.Text, err = v.reqString(path+".badge", bm, "text", MaxBadgeChars); err != nil {
			return nil, err
		}
		if r.Badge.Tone, err = v.tone(path+".badge", bm); err != nil {
			return nil, err
		}
	}
	if r.Tone, err = v.tone(path, m); err != nil {
		return nil, err
	}
	if r.Link, err = v.optURL(path, m, "link"); err != nil {
		return nil, err
	}
	if raw, has := m["actions"]; has {
		if r.Actions, err = v.actionList(path+".actions", raw, 0, MaxRowActions); err != nil {
			return nil, err
		}
	}
	if raw, has := m["ref"]; has {
		if r.Ref, err = v.ref(path+".ref", raw); err != nil {
			return nil, err
		}
	}
	return r, nil
}

func (v *validator) ref(path string, raw any) (*Ref, error) {
	m, err := v.object(path, raw, []string{"kind", "id"}, "{kind, id}")
	if err != nil {
		return nil, err
	}
	kind, _ := m["kind"].(string)
	if !slices.Contains(refKinds, kind) {
		return nil, v.errf("%s.kind must be one of %s", path, strings.Join(refKinds, ", "))
	}
	id, isInt := m["id"].(int64)
	if !isInt || id <= 0 {
		return nil, v.errf("%s.id must be a positive integer", path)
	}
	if (kind == RefAction || kind == RefReminder) && !v.opts.BuiltIn {
		article := "a"
		if kind == RefAction {
			article = "an"
		}
		return nil, v.errf("%s: %s %s ref is only for built-in automations", path, article, kind)
	}
	return &Ref{Kind: kind, ID: id}, nil
}

func (v *validator) table(path string, m map[string]any) (*Table, error) {
	t := &Table{}
	var err error
	if t.Title, err = v.optString(path, m, "title", MaxTableTitleChars); err != nil {
		return nil, err
	}
	cols, err := v.array(path+".columns", m["columns"], 1, MaxColumns, "columns")
	if err != nil {
		return nil, err
	}
	t.Columns = make([]Column, 0, len(cols))
	for i, raw := range cols {
		cp := path + ".columns[" + strconv.Itoa(i) + "]"
		cm, err := v.object(cp, raw, []string{"title", "align"}, "{title, align?}")
		if err != nil {
			return nil, err
		}
		c := Column{Align: "leading"}
		if c.Title, err = v.reqString(cp, cm, "title", MaxColumnTitleChars); err != nil {
			return nil, err
		}
		if a, has := cm["align"]; has {
			s, _ := a.(string)
			if s != "leading" && s != "trailing" {
				return nil, v.errf("%s.align must be leading or trailing", cp)
			}
			c.Align = s
		}
		t.Columns = append(t.Columns, c)
	}
	rows, err := v.array(path+".rows", m["rows"], 0, MaxTableRows, "rows")
	if err != nil {
		return nil, err
	}
	v.rows += len(rows)
	t.Rows = make([][]Cell, 0, len(rows))
	for i, raw := range rows {
		rp := path + ".rows[" + strconv.Itoa(i) + "]"
		cells, ok := raw.([]any)
		if !ok {
			return nil, v.errf("%s must be an array of cells", rp)
		}
		if len(cells) != len(t.Columns) {
			return nil, v.errf("%s has %d cells; the table has %d columns", rp, len(cells), len(t.Columns))
		}
		row := make([]Cell, 0, len(cells))
		for j, raw := range cells {
			c, err := v.cell(rp+"["+strconv.Itoa(j)+"]", raw)
			if err != nil {
				return nil, err
			}
			row = append(row, c)
		}
		t.Rows = append(t.Rows, row)
	}
	return t, nil
}

func (v *validator) cell(path string, raw any) (Cell, error) {
	if s, ok := raw.(string); ok {
		s = strings.TrimSpace(s)
		if n := utf8.RuneCountInString(s); n > MaxCellChars {
			return Cell{}, v.errf("%s is %d characters; the limit is %d", path, n, MaxCellChars)
		}
		return Cell{Text: s}, nil
	}
	m, err := v.object(path, raw, []string{"text", "tone", "link"}, "{text, tone?, link?} or a string")
	if err != nil {
		return Cell{}, err
	}
	var c Cell
	if c.Text, err = v.reqString(path, m, "text", MaxCellChars); err != nil {
		return Cell{}, err
	}
	if c.Tone, err = v.tone(path, m); err != nil {
		return Cell{}, err
	}
	if c.Link, err = v.optURL(path, m, "link"); err != nil {
		return Cell{}, err
	}
	return c, nil
}

func (v *validator) person(path string, m map[string]any) (*Person, error) {
	p := &Person{Lines: []PersonLine{}}
	var err error
	if p.Name, err = v.reqString(path, m, "name", MaxPersonNameChars); err != nil {
		return nil, err
	}
	if p.Role, err = v.optString(path, m, "role", MaxPersonRoleChars); err != nil {
		return nil, err
	}
	if raw, has := m["avatar"]; has {
		am, err := v.object(path+".avatar", raw, []string{"slack_user"}, `{slack_user: "<account>:<user id>"}`)
		if err != nil {
			return nil, err
		}
		u, _ := am["slack_user"].(string)
		u = strings.TrimSpace(u)
		acct, user, found := strings.Cut(u, ":")
		if !found || acct == "" || user == "" || utf8.RuneCountInString(u) > MaxSlackUserChars {
			return nil, v.errf(`%s.avatar.slack_user must be "<account>:<user id>"`, path)
		}
		p.Avatar = &Avatar{SlackUser: u}
	}
	if raw, has := m["lines"]; has {
		lines, err := v.array(path+".lines", raw, 0, MaxPersonLines, "lines")
		if err != nil {
			return nil, err
		}
		for i, raw := range lines {
			l, err := v.personLine(path+".lines["+strconv.Itoa(i)+"]", raw)
			if err != nil {
				return nil, err
			}
			p.Lines = append(p.Lines, l)
		}
	}
	if p.Link, err = v.optURL(path, m, "link"); err != nil {
		return nil, err
	}
	return p, nil
}

func (v *validator) personLine(path string, raw any) (PersonLine, error) {
	if s, ok := raw.(string); ok {
		s = strings.TrimSpace(s)
		if s == "" {
			return PersonLine{}, v.errf("%s must be a non-empty string", path)
		}
		if n := utf8.RuneCountInString(s); n > MaxPersonLineChars {
			return PersonLine{}, v.errf("%s is %d characters; the limit is %d", path, n, MaxPersonLineChars)
		}
		return PersonLine{Text: s}, nil
	}
	m, err := v.object(path, raw, []string{"text", "tone"}, "{text, tone?} or a string")
	if err != nil {
		return PersonLine{}, err
	}
	var l PersonLine
	if l.Text, err = v.reqString(path, m, "text", MaxPersonLineChars); err != nil {
		return PersonLine{}, err
	}
	if l.Tone, err = v.tone(path, m); err != nil {
		return PersonLine{}, err
	}
	return l, nil
}

func (v *validator) metrics(path string, m map[string]any) (*Metrics, error) {
	items, err := v.array(path+".items", m["items"], 1, MaxMetrics, "items")
	if err != nil {
		return nil, err
	}
	out := &Metrics{Items: make([]Metric, 0, len(items))}
	for i, raw := range items {
		ip := path + ".items[" + strconv.Itoa(i) + "]"
		im, err := v.object(ip, raw, []string{"label", "value", "tone", "hint"}, "{label, value, tone?, hint?}")
		if err != nil {
			return nil, err
		}
		var x Metric
		if x.Label, err = v.reqString(ip, im, "label", MaxMetricLabelChars); err != nil {
			return nil, err
		}
		if x.Value, err = v.reqString(ip, im, "value", MaxMetricValueChars); err != nil {
			return nil, err
		}
		if x.Tone, err = v.tone(ip, im); err != nil {
			return nil, err
		}
		if x.Hint, err = v.optString(ip, im, "hint", MaxMetricHintChars); err != nil {
			return nil, err
		}
		out.Items = append(out.Items, x)
	}
	return out, nil
}

func (v *validator) link(path string, m map[string]any) (*Link, error) {
	l := &Link{}
	var err error
	if l.Title, err = v.reqString(path, m, "title", MaxLinkTitleChars); err != nil {
		return nil, err
	}
	if _, has := m["url"]; !has {
		return nil, v.errf("%s.url must be an http, https or watchtower-nav:// link with a host", path)
	}
	if l.URL, err = v.optURL(path, m, "url"); err != nil {
		return nil, err
	}
	if l.Subtitle, err = v.optString(path, m, "subtitle", MaxLinkSubtitleChars); err != nil {
		return nil, err
	}
	return l, nil
}

func (v *validator) actionsBlock(path string, m map[string]any) (*ActionsBlock, error) {
	actions, err := v.actionList(path+".actions", m["actions"], 1, MaxBlockActions)
	if err != nil {
		return nil, err
	}
	return &ActionsBlock{Actions: actions}, nil
}

// actionList validates an array of min…max actions through the one action
// grammar and counts them against MaxActions.
func (v *validator) actionList(path string, raw any, minN, maxN int) ([]db.InboxAction, error) {
	list, err := v.array(path, raw, minN, maxN, "actions")
	if err != nil {
		return nil, err
	}
	out := make([]db.InboxAction, 0, len(list))
	for i, item := range list {
		a, err := ValidateAction(v.fn, path, i, item, v.opts)
		if err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	v.actions += len(out)
	return out, nil
}

// array checks raw is an array of min…max items.
func (v *validator) array(path string, raw any, minN, maxN int, noun string) ([]any, error) {
	list, ok := raw.([]any)
	if !ok {
		return nil, v.errf("%s must be an array", path)
	}
	if len(list) > maxN {
		return nil, v.errf("%s has %d %s; the limit is %d", path, len(list), noun, maxN)
	}
	if len(list) < minN {
		return nil, v.errf("%s needs at least %d of %s", path, minN, noun)
	}
	return list, nil
}

// object checks raw is an object with only keys (unknown ones refused in
// sorted order, so the message is stable).
func (v *validator) object(path string, raw any, keys []string, shape string) (map[string]any, error) {
	m, ok := raw.(map[string]any)
	if !ok {
		return nil, v.errf("%s must be an object %s", path, shape)
	}
	return m, v.knownKeys(path, m, keys)
}

func (v *validator) knownKeys(path string, m map[string]any, keys []string) error {
	for _, k := range slices.Sorted(maps.Keys(m)) {
		if !slices.Contains(keys, k) {
			return v.errf("%s: unknown field %q", path, k)
		}
	}
	return nil
}

// reqString is m[key], trimmed, non-empty and at most maxChars characters.
func (v *validator) reqString(path string, m map[string]any, key string, maxChars int) (string, error) {
	s, ok := m[key].(string)
	s = strings.TrimSpace(s)
	if !ok || s == "" {
		return "", v.errf("%s.%s must be a non-empty string", path, key)
	}
	if n := utf8.RuneCountInString(s); n > maxChars {
		return "", v.errf("%s.%s is %d characters; the limit is %d", path, key, n, maxChars)
	}
	return s, nil
}

// optString is m[key], trimmed and at most maxChars characters; absent or
// blank is "".
func (v *validator) optString(path string, m map[string]any, key string, maxChars int) (string, error) {
	raw, has := m[key]
	if !has {
		return "", nil
	}
	s, ok := raw.(string)
	if !ok {
		return "", v.errf("%s.%s must be a string", path, key)
	}
	s = strings.TrimSpace(s)
	if n := utf8.RuneCountInString(s); n > maxChars {
		return "", v.errf("%s.%s is %d characters; the limit is %d", path, key, n, maxChars)
	}
	return s, nil
}

// tone is m["tone"], one of Tones, or "" when absent.
func (v *validator) tone(path string, m map[string]any) (string, error) {
	raw, has := m["tone"]
	if !has {
		return "", nil
	}
	s, _ := raw.(string)
	if !slices.Contains(Tones, s) {
		return "", v.errf("%s.tone must be one of %s", path, strings.Join(Tones, ", "))
	}
	return s, nil
}

// optURL is m[key] under the card URL rules, or "" when absent.
func (v *validator) optURL(path string, m map[string]any, key string) (string, error) {
	raw, has := m[key]
	if !has {
		return "", nil
	}
	s, ok := raw.(string)
	if !ok {
		return "", v.errf("%s.%s must be an http, https or watchtower-nav:// link with a host", path, key)
	}
	return CheckURL(v.fn, path+"."+key, strings.TrimSpace(s))
}

func (v *validator) errf(format string, a ...any) error {
	return errorf("%s(): "+format, append([]any{v.fn}, a...)...)
}
