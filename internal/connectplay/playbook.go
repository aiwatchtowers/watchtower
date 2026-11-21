// Package connectplay reads the connect playbooks: the guide pages under
// docs/guide/connect/ that are at once the connect assistant's script, a
// guide page and what the help chat answers from (agent connect spec §5.1).
// Each page carries a fenced `connect` block (service, vendor, domains,
// tools, secrets, options) and a numbered `## Steps` list whose items say who
// acts: **Agent:**, **You:**, **You only:** or **Check:**. Parsing validates
// the page; an invalid playbook never loads.
package connectplay

import (
	"cmp"
	"fmt"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"watchtower/docs/guide"
)

// dir is the playbooks' folder inside the embedded guide.
const dir = "connect/"

// Playbook is one parsed connect playbook.
type Playbook struct {
	// ID is the file's basename ("slack", "company-google").
	ID string
	// Path is the guide path ("connect/slack.md").
	Path string
	// Service is the connect service id: a Swift ConnectionService raw value,
	// "company", or "google_own_project".
	Service string
	// Vendor is the company vendor (CompanyVendors); set only for "company".
	Vendor string
	// Domains are the bare hosts the agent may work on in the browser.
	Domains []string
	// Tools are the connect tools (KnownTools) the playbook may call.
	Tools []string
	// Secrets are the request_secret kinds (KnownSecrets) it may ask for.
	Secrets []string
	// Options are the connect_start options the playbook names.
	Options []string
	// Text is the whole page.
	Text string
	// Steps is the numbered list under "## Steps".
	Steps []Step

	// sections holds the steps of every section that has any ("Steps",
	// "Slack Live"), by heading.
	sections map[string][]Step
}

// Step is one numbered item of a steps list.
type Step struct {
	N int
	// Actor is "agent", "customer", "customer_only" or "check".
	Actor string
	Text  string
}

// KnownTools are the connect tools a playbook may list (spec §5.3, §5.4).
// slack_live_probe is allowed only in slack.md: the Desktop runs `slack live
// probe --provider <p> --json` and returns the row's status.
var KnownTools = []string{
	"connect_status", "connect_start", "connect_wait", "connect_cancel",
	"request_secret", "set_fields", "choose",
	"company_draft", "company_check", "company_publish",
	"slack_live_probe",
}

// KnownSecrets are the request_secret kinds; each names the verb the Desktop
// hands the secret to on stdin (spec §5.3).
var KnownSecrets = []string{
	"slack_config_token", "imap_password", "caldav_password", "ics_url",
	"linear_api_key", "mcp_secret", "google_client_secret", "atlassian_client_secret",
}

// CompanyVendors is the company set's vendor order: the setup wizard's
// (Swift CompanyVendor.allCases, which CompanySetupWizardModel.steps walks).
// ForService("company", "") returns the company playbooks in this order.
var CompanyVendors = []string{"slack", "google", "atlassian", "linear", "microsoft"}

// knownServices are the connect service ids: the Swift ConnectionService raw
// values, plus "company" (the setup wizard) and "google_own_project" (a
// bring-your-own Google client, kept apart from the personal Google run).
var knownServices = []string{
	"slack", "google", "email", "calendar", "jira", "linear", "quickConnections",
	"company", "google_own_project",
}

// requiredSections are the template's sections, in this order.
var requiredSections = []string{"What you get", "Before you start", "Steps", "If something goes wrong"}

// actors maps a step tag to its Actor.
var actors = map[string]string{
	"Agent": "agent", "You": "customer", "You only": "customer_only", "Check": "check",
}

var (
	idRe       = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)
	optionRe   = regexp.MustCompile(`^[a-z][a-z0-9_]*$`)
	numberedRe = regexp.MustCompile(`^(\d+)\.\s+(.*)$`)
	taggedRe   = regexp.MustCompile(`^\*\*(Agent|You|You only|Check):\*\*\s+(.+)$`)
)

// Load reads and validates connect/<id>.md.
func Load(id string) (Playbook, error) {
	if !idRe.MatchString(id) {
		return Playbook{}, fmt.Errorf("connect playbook %q: not a playbook id", id)
	}
	p := dir + id + ".md"
	b, err := guide.ReadFile(p)
	if err != nil {
		return Playbook{}, fmt.Errorf("connect playbook %q: %w", id, err)
	}
	return parse(id, p, string(b))
}

// All loads every playbook, sorted by path.
func All() ([]Playbook, error) {
	var out []Playbook
	for _, pg := range guide.Pages() {
		name, ok := strings.CutPrefix(pg.Path, dir)
		if !ok {
			continue
		}
		p, err := Load(strings.TrimSuffix(name, ".md"))
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, nil
}

// ForService returns the playbooks of a connect service. For "company" with
// an empty vendor it is the whole company set in CompanyVendors order; a
// vendor narrows it to that vendor's page. A service with no playbook is an
// error.
func ForService(service, vendor string) ([]Playbook, error) {
	if !slices.Contains(knownServices, service) {
		return nil, fmt.Errorf("connect service %q: unknown", service)
	}
	pbs, err := All()
	if err != nil {
		return nil, err
	}
	pbs = slices.DeleteFunc(pbs, func(p Playbook) bool {
		return p.Service != service || (vendor != "" && p.Vendor != vendor)
	})
	if len(pbs) == 0 {
		return nil, fmt.Errorf("connect service %q (vendor %q): no playbook", service, vendor)
	}
	sortForService(pbs)
	return pbs, nil
}

// sortForService orders company playbooks by CompanyVendors; others keep
// their path order (stable).
func sortForService(pbs []Playbook) {
	slices.SortStableFunc(pbs, func(a, b Playbook) int {
		return cmp.Compare(slices.Index(CompanyVendors, a.Vendor), slices.Index(CompanyVendors, b.Vendor))
	})
}

// stepItem is one numbered list item of a section, tagged or not.
type stepItem struct {
	n      int
	tagged bool
	step   Step
}

// parse reads one playbook page and validates it.
func parse(id, path, body string) (Playbook, error) {
	p := Playbook{ID: id, Path: path, Text: body}
	fail := func(format string, args ...any) (Playbook, error) {
		return Playbook{}, fmt.Errorf("%s: "+format, append([]any{id}, args...)...)
	}

	var (
		headings []string
		section  string
		items    = map[string][]stepItem{}
		last     *stepItem // the item a continuation line belongs to
		fence    string
		inBlock  bool
		block    []string
		blocks   int
	)
	for _, line := range strings.Split(body, "\n") {
		trim := strings.TrimSpace(line)
		switch {
		case inBlock:
			if strings.HasPrefix(trim, "```") {
				inBlock = false
				continue
			}
			block = append(block, trim)
			continue
		case fence != "":
			if strings.HasPrefix(trim, fence) {
				fence = ""
			}
			continue
		case trim == "```connect":
			inBlock = true
			blocks++
			last = nil
			continue
		case strings.HasPrefix(trim, "```") || strings.HasPrefix(trim, "~~~"):
			fence = trim[:3]
			last = nil
			continue
		}
		if h, ok := strings.CutPrefix(line, "## "); ok {
			section = strings.TrimSpace(h)
			headings = append(headings, section)
			last = nil
			continue
		}
		if m := numberedRe.FindStringSubmatch(line); m != nil {
			n, _ := strconv.Atoi(m[1])
			it := stepItem{n: n}
			if t := taggedRe.FindStringSubmatch(strings.TrimSpace(m[2])); t != nil {
				it.tagged = true
				it.step = Step{N: n, Actor: actors[t[1]], Text: strings.TrimSpace(t[2])}
			}
			items[section] = append(items[section], it)
			last = &items[section][len(items[section])-1]
			continue
		}
		if last != nil && trim != "" && line != trim && last.tagged {
			last.step.Text += " " + trim
			continue
		}
		last = nil
	}
	if inBlock {
		return fail("the connect block never closes")
	}
	if blocks != 1 {
		return fail("want exactly one connect block, found %d", blocks)
	}
	if err := p.readBlock(block); err != nil {
		return fail("%v", err)
	}

	pos := -1
	for _, want := range requiredSections {
		i := slices.Index(headings, want)
		if i < 0 {
			return fail("no \"## %s\" section", want)
		}
		if i < pos {
			return fail("\"## %s\" is out of the template's order", want)
		}
		pos = i
	}

	p.sections = map[string][]Step{}
	for _, name := range headings {
		list := items[name]
		if name != "Steps" && !slices.ContainsFunc(list, func(it stepItem) bool { return it.tagged }) {
			continue
		}
		if _, done := p.sections[name]; done {
			continue
		}
		var steps []Step
		for i, it := range list {
			if !it.tagged {
				return fail("%s item %d has no **Agent:**/**You:**/**You only:**/**Check:** tag", name, it.n)
			}
			if it.n != i+1 {
				return fail("%s are numbered %d after %d", name, it.n, i)
			}
			steps = append(steps, it.step)
		}
		p.sections[name] = steps
	}
	p.Steps = p.sections["Steps"]
	if len(p.Steps) == 0 {
		return fail("\"## Steps\" has no numbered steps")
	}

	res := revealRes[revealVendor(p)]
	for _, name := range headings {
		for _, s := range p.sections[name] {
			if s.Actor == "customer_only" || !matchesAny(res, s.Text) {
				continue
			}
			where := "step"
			if name != "Steps" {
				where = name + " step"
			}
			return fail("%s %d reveals a secret but is not \"You only\"", where, s.N)
		}
	}
	return p, nil
}

// readBlock fills the playbook from its connect block's "key: a, b" lines
// and validates the values.
func (p *Playbook) readBlock(lines []string) error {
	seen := map[string]bool{}
	for _, line := range lines {
		if line == "" {
			continue
		}
		key, val, ok := strings.Cut(line, ":")
		if !ok {
			return fmt.Errorf("connect block line %q is not \"key: values\"", line)
		}
		key = strings.TrimSpace(key)
		if seen[key] {
			return fmt.Errorf("connect block repeats %q", key)
		}
		seen[key] = true
		var list []string
		for _, v := range strings.Split(val, ",") {
			if v = strings.TrimSpace(v); v != "" {
				list = append(list, v)
			}
		}
		switch key {
		case "service":
			p.Service = strings.Join(list, ",")
		case "vendor":
			p.Vendor = strings.Join(list, ",")
		case "domains":
			p.Domains = list
		case "tools":
			p.Tools = list
		case "secrets":
			p.Secrets = list
		case "options":
			p.Options = list
		default:
			return fmt.Errorf("connect block has an unknown key %q", key)
		}
	}

	if !slices.Contains(knownServices, p.Service) {
		return fmt.Errorf("unknown service %q", p.Service)
	}
	if (p.Service == "company") != (p.Vendor != "") {
		return fmt.Errorf("vendor %q: a vendor is required for service company and only there", p.Vendor)
	}
	if p.Vendor != "" && !slices.Contains(CompanyVendors, p.Vendor) {
		return fmt.Errorf("unknown vendor %q", p.Vendor)
	}
	if len(p.Domains) == 0 {
		return fmt.Errorf("no domains")
	}
	for _, d := range p.Domains {
		if !bareHost(d) {
			return fmt.Errorf("domain %q is not a bare lowercase host (no scheme, path, port or wildcard)", d)
		}
	}
	if len(p.Tools) == 0 {
		return fmt.Errorf("no tools")
	}
	if err := knownAndUnique("tool", p.Tools, KnownTools); err != nil {
		return err
	}
	if slices.Contains(p.Tools, "slack_live_probe") && p.ID != "slack" {
		return fmt.Errorf("slack_live_probe is allowed only in slack.md")
	}
	if err := knownAndUnique("secret", p.Secrets, KnownSecrets); err != nil {
		return err
	}
	if (len(p.Secrets) > 0) != slices.Contains(p.Tools, "request_secret") {
		return fmt.Errorf("secrets and request_secret go together: secrets %v, tools %v", p.Secrets, p.Tools)
	}
	for _, o := range p.Options {
		if !optionRe.MatchString(o) {
			return fmt.Errorf("option %q is not a lowercase name", o)
		}
	}
	return nil
}

func knownAndUnique(kind string, got, known []string) error {
	for i, v := range got {
		if !slices.Contains(known, v) {
			return fmt.Errorf("unknown %s %q", kind, v)
		}
		if slices.Contains(got[:i], v) {
			return fmt.Errorf("%s %q listed twice", kind, v)
		}
	}
	return nil
}

// bareHost reports whether d is a lowercase host name with a dot and nothing
// else: no scheme, path, port, userinfo or wildcard.
func bareHost(d string) bool {
	if d != strings.ToLower(d) || !strings.Contains(d, ".") || strings.ContainsAny(d, "*/:@?#") || strings.HasSuffix(d, ".") {
		return false
	}
	u, err := url.Parse("https://" + d)
	return err == nil && u.Host == d && u.Hostname() == d
}
