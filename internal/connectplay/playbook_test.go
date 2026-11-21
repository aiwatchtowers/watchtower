package connectplay

import (
	"net/url"
	"os"
	"regexp"
	"slices"
	"strings"
	"testing"

	"watchtower/docs/guide"
)

func all(t *testing.T) []Playbook {
	t.Helper()
	pbs, err := All()
	if err != nil {
		t.Fatal(err)
	}
	if len(pbs) == 0 {
		t.Fatal("no playbooks under docs/guide/connect/")
	}
	return pbs
}

// page builds a playbook body around a connect block and a Steps list.
func page(block, steps string) string {
	return "# Connect Acme\n\nLede.\n\n## What you get\n\nA thing.\n\n## Before you start\n\nAn account.\n\n" +
		"## Steps\n\n" + steps + "\n\n## If something goes wrong\n\n- **Busy.** Wait.\n\n" +
		"```connect\n" + block + "\n```\n"
}

const okBlock = "service: slack\ndomains: api.slack.com\ntools: connect_status, connect_start, connect_wait, request_secret\nsecrets: slack_config_token"

const okSteps = "1. **Agent:** call `connect_status`.\n2. **You:** sign in.\n3. **You only:** press **Generate Token**.\n4. **Check:** `connect_wait` says connected."

func TestParse_Accepts(t *testing.T) {
	p, err := parse("acme", "connect/acme.md", page(okBlock, okSteps))
	if err != nil {
		t.Fatal(err)
	}
	if p.Service != "slack" || p.Path != "connect/acme.md" || !slices.Equal(p.Domains, []string{"api.slack.com"}) {
		t.Fatalf("got %+v", p)
	}
	want := []Step{
		{1, "agent", "call `connect_status`."},
		{2, "customer", "sign in."},
		{3, "customer_only", "press **Generate Token**."},
		{4, "check", "`connect_wait` says connected."},
	}
	if !slices.Equal(p.Steps, want) {
		t.Fatalf("steps = %+v", p.Steps)
	}
}

func TestPlaybooks_SlackLiveSection(t *testing.T) {
	p, err := Load("slack")
	if err != nil {
		t.Fatal(err)
	}
	live, ok := p.sections["Slack Live"]
	if !ok || len(live) == 0 {
		t.Fatal("slack.md has no steps under ## Slack Live")
	}
	for _, s := range live {
		if s.Actor == "agent" {
			t.Errorf("Slack Live step %d is an agent step: the vendor's connector is turned on in words only", s.N)
		}
	}
	for _, p := range all(t) {
		has := slices.Contains(p.Tools, "slack_live_probe")
		if has != (p.ID == "slack") {
			t.Errorf("%s: slack_live_probe in tools = %v; only slack.md may use it", p.ID, has)
		}
	}
	if _, err := parse("acme", "connect/acme.md", page(okBlock+"\ntools: slack_live_probe", okSteps)); err == nil {
		t.Error("a duplicate tools line parsed")
	}
	other := strings.Replace(okBlock, "request_secret", "request_secret, slack_live_probe", 1)
	if _, err := parse("acme", "connect/acme.md", page(other, okSteps)); err == nil || !strings.Contains(err.Error(), "slack_live_probe") {
		t.Errorf("slack_live_probe outside slack.md: err = %v", err)
	}
}

func TestPlaybooks_AllParse(t *testing.T) {
	ids := map[string]bool{}
	for _, p := range guide.Pages() {
		if id, ok := strings.CutPrefix(p.Path, dir); ok {
			ids[strings.TrimSuffix(id, ".md")] = true
		}
	}
	pbs := all(t)
	if len(pbs) != len(ids) {
		t.Fatalf("All() = %d playbooks, %d files under connect/", len(pbs), len(ids))
	}
	for _, p := range pbs {
		if !ids[p.ID] || p.Path != dir+p.ID+".md" {
			t.Errorf("%s: unexpected id/path %q", p.ID, p.Path)
		}
		if !slices.Contains(knownServices, p.Service) {
			t.Errorf("%s: unknown service %q", p.ID, p.Service)
		}
		if len(p.Domains) == 0 {
			t.Errorf("%s: no domains", p.ID)
		}
		for _, d := range p.Domains {
			u, err := url.Parse("https://" + d)
			if err != nil || u.Host != d || strings.ContainsAny(d, "*/:") {
				t.Errorf("%s: domain %q is not a bare host", p.ID, d)
			}
		}
		for _, tool := range p.Tools {
			if !slices.Contains(KnownTools, tool) {
				t.Errorf("%s: unknown tool %q", p.ID, tool)
			}
		}
		for _, s := range p.Secrets {
			if !slices.Contains(KnownSecrets, s) {
				t.Errorf("%s: unknown secret %q", p.ID, s)
			}
		}
		if len(p.Steps) == 0 || p.Text == "" {
			t.Errorf("%s: no steps or text", p.ID)
		}
	}
}

func TestPlaybooks_TemplateSections(t *testing.T) {
	for _, p := range all(t) {
		last := -1
		for _, h := range requiredSections {
			i := strings.Index(p.Text, "\n## "+h+"\n")
			if i < 0 || i < last {
				t.Errorf("%s: ## %s missing or out of order", p.ID, h)
			}
			last = i
		}
	}
	swapped := strings.Replace(page(okBlock, okSteps),
		"## What you get\n\nA thing.\n\n## Before you start\n\nAn account.",
		"## Before you start\n\nAn account.\n\n## What you get\n\nA thing.", 1)
	if _, err := parse("acme", "connect/acme.md", swapped); err == nil {
		t.Error("sections out of order parsed")
	}
	missing := strings.Replace(page(okBlock, okSteps), "## If something goes wrong", "## Trouble", 1)
	if _, err := parse("acme", "connect/acme.md", missing); err == nil {
		t.Error("a missing section parsed")
	}
}

func TestPlaybooks_RevealStepsAreCustomerOnly(t *testing.T) {
	for _, p := range all(t) {
		res := revealRes[revealVendor(p)]
		for name, steps := range p.sections {
			for _, s := range steps {
				if matchesAny(res, s.Text) && s.Actor != "customer_only" {
					t.Errorf("%s: %s step %d reveals a secret but is %s", p.ID, name, s.N, s.Actor)
				}
			}
		}
	}
	bad := strings.Replace(okSteps, "**You only:** press **Generate Token**", "**Agent:** press Generate Token", 1)
	_, err := parse("slack", "connect/slack.md", page(okBlock, bad))
	if err == nil || err.Error() != `slack: step 3 reveals a secret but is not "You only"` {
		t.Fatalf("err = %v", err)
	}
	companyBlock := func(vendor string) string {
		return "service: company\nvendor: " + vendor + "\ndomains: example.com\ntools: connect_status, company_draft"
	}
	for _, c := range []struct{ vendor, phrase string }{
		{"google", "press **Create** on the OAuth client form"},
		{"google", "Click Create on the OAuth client form"},
		{"google", "click `Create`"},
		{"google", "press the Create button"},
		{"google", "copy the secret from the dialog"},
		{"atlassian", "open the app's **Settings**"},
		{"atlassian", "Open the app's Settings page"},
		{"atlassian", "open `Settings`"},
		{"slack", "press Generate Token"},
		{"slack", "press `Generate Token`"},
		{"slack", "press *Generate  Token*"},
	} {
		for _, actor := range []string{"Agent", "You", "Check"} {
			steps := "1. **" + actor + ":** " + c.phrase + "."
			if _, err := parse("company-"+c.vendor, "connect/x.md", page(companyBlock(c.vendor), steps)); err == nil {
				t.Errorf("%s: a %s step %q parsed", c.vendor, actor, c.phrase)
			}
		}
		if _, err := parse("company-"+c.vendor, "connect/x.md", page(companyBlock(c.vendor), "1. **You only:** "+c.phrase+".")); err != nil {
			t.Errorf("%s: a You only step %q failed: %v", c.vendor, c.phrase, err)
		}
	}
	// Up to the button is the agent's: naming the form or the token section
	// without pressing the button is allowed.
	for _, c := range []struct{ vendor, phrase string }{
		{"google", "fill the OAuth client form up to **Create** and call `request_secret`"},
		{"slack", "scroll to **Your App Configuration Tokens** and call `request_secret`"},
	} {
		if _, err := parse("company-"+c.vendor, "connect/x.md", page(companyBlock(c.vendor), "1. **Agent:** "+c.phrase+".")); err != nil {
			t.Errorf("%s: agent step %q refused: %v", c.vendor, c.phrase, err)
		}
	}
	for _, vendor := range []string{"google", "atlassian", "slack"} {
		if len(revealPages[vendor]) == 0 {
			t.Errorf("no reveal pages for %s", vendor)
		}
	}
}

func TestPlaybooks_SecretsNeedRequestSecret(t *testing.T) {
	for _, p := range all(t) {
		has := slices.Contains(p.Tools, "request_secret")
		if (len(p.Secrets) > 0) != has {
			t.Errorf("%s: secrets %v but request_secret in tools = %v", p.ID, p.Secrets, has)
		}
	}
	noTool := strings.Replace(okBlock, ", request_secret", "", 1)
	if _, err := parse("acme", "connect/acme.md", page(noTool, okSteps)); err == nil {
		t.Error("secrets without request_secret parsed")
	}
	noSecret := strings.Replace(okBlock, "\nsecrets: slack_config_token", "", 1)
	if _, err := parse("acme", "connect/acme.md", page(noSecret, okSteps)); err == nil {
		t.Error("request_secret without secrets parsed")
	}
}

var (
	emailAddr = regexp.MustCompile(`[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)`)
	slackID   = regexp.MustCompile(`\b[TUWCDG]0[A-Z0-9]{6,}\b`)
)

func TestPlaybooks_PublicSafe(t *testing.T) {
	for _, p := range all(t) {
		for _, m := range emailAddr.FindAllStringSubmatch(p.Text, -1) {
			if d := strings.ToLower(m[1]); d != "example.com" && !strings.HasSuffix(d, ".example.com") {
				t.Errorf("%s: address %q outside example.com", p.ID, m[0])
			}
		}
		if id := slackID.FindString(p.Text); id != "" {
			t.Errorf("%s: Slack-style id %q", p.ID, id)
		}
		if strings.Contains(p.Text, "/Users/") {
			t.Errorf("%s: local path", p.ID)
		}
	}
}

func TestParse_RejectsMissingBlock(t *testing.T) {
	body := strings.Split(page(okBlock, okSteps), "```connect")[0]
	if _, err := parse("acme", "connect/acme.md", body); err == nil || !strings.Contains(err.Error(), "connect block") {
		t.Fatalf("err = %v", err)
	}
	twice := page(okBlock, okSteps) + "\n```connect\n" + okBlock + "\n```\n"
	if _, err := parse("acme", "connect/acme.md", twice); err == nil {
		t.Error("two connect blocks parsed")
	}
}

func TestParse_RejectsUnknownTool(t *testing.T) {
	block := strings.Replace(okBlock, "connect_wait", "run_shell", 1)
	if _, err := parse("acme", "connect/acme.md", page(block, okSteps)); err == nil || !strings.Contains(err.Error(), "run_shell") {
		t.Fatalf("err = %v", err)
	}
	secret := strings.Replace(okBlock, "slack_config_token", "root_password", 1)
	if _, err := parse("acme", "connect/acme.md", page(secret, okSteps)); err == nil {
		t.Error("an unknown secret parsed")
	}
	key := okBlock + "\nscopes: all"
	if _, err := parse("acme", "connect/acme.md", page(key, okSteps)); err == nil {
		t.Error("an unknown block key parsed")
	}
	svc := strings.Replace(okBlock, "service: slack", "service: dropbox", 1)
	if _, err := parse("acme", "connect/acme.md", page(svc, okSteps)); err == nil {
		t.Error("an unknown service parsed")
	}
}

func TestParse_RejectsSchemeInDomain(t *testing.T) {
	for _, d := range []string{"https://api.slack.com", "api.slack.com/apps", "*.slack.com", "api.slack.com:443", "localhost", "API.slack.com", ""} {
		block := strings.Replace(okBlock, "domains: api.slack.com", "domains: "+d, 1)
		if _, err := parse("acme", "connect/acme.md", page(block, okSteps)); err == nil {
			t.Errorf("domain %q parsed", d)
		}
	}
}

func TestParse_CompanyNeedsVendor(t *testing.T) {
	company := "service: company\ndomains: example.com\ntools: connect_status, company_draft"
	if _, err := parse("acme", "connect/acme.md", page(company, okSteps)); err == nil {
		t.Error("company without vendor parsed")
	}
	if _, err := parse("acme", "connect/acme.md", page(company+"\nvendor: dropbox", okSteps)); err == nil {
		t.Error("an unknown vendor parsed")
	}
	if _, err := parse("acme", "connect/acme.md", page(okBlock+"\nvendor: slack", okSteps)); err == nil {
		t.Error("vendor on a personal playbook parsed")
	}
	p, err := parse("acme", "connect/acme.md", page(company+"\nvendor: linear", okSteps))
	if err != nil || p.Vendor != "linear" {
		t.Fatalf("p = %+v, err = %v", p, err)
	}
}

func TestParse_RejectsBadSteps(t *testing.T) {
	for name, steps := range map[string]string{
		"untagged":   "1. **Agent:** a.\n2. Press it.",
		"numbering":  "1. **Agent:** a.\n3. **You:** b.",
		"unknown":    "1. **Robot:** a.",
		"empty list": "Nothing to do.",
	} {
		if _, err := parse("acme", "connect/acme.md", page(okBlock, steps)); err == nil {
			t.Errorf("%s steps parsed", name)
		}
	}
	p, err := parse("acme", "connect/acme.md", page(okBlock, "1. **Agent:** open the page\n   and wait.\n2. **You:** sign in."))
	if err != nil || p.Steps[0].Text != "open the page and wait." {
		t.Fatalf("continuation: %+v, %v", p.Steps, err)
	}
}

func TestLoad_RejectsBadID(t *testing.T) {
	for _, id := range []string{"", "../README", "Slack", "slack.md", "nope"} {
		if _, err := Load(id); err == nil {
			t.Errorf("Load(%q) succeeded", id)
		}
	}
}

func TestForService(t *testing.T) {
	pbs, err := ForService("slack", "")
	if err != nil || len(pbs) != 1 || pbs[0].ID != "slack" {
		t.Fatalf("slack: %v, %v", pbs, err)
	}
	if _, err := ForService("dropbox", ""); err == nil {
		t.Error("an unknown service succeeded")
	}
	if _, err := ForService("company", "dropbox"); err == nil {
		t.Error("a vendor with no playbook succeeded")
	}
	company := []Playbook{{ID: "company-microsoft", Vendor: "microsoft"}, {ID: "company-google", Vendor: "google"}, {ID: "company-slack", Vendor: "slack"}}
	sortForService(company)
	var got []string
	for _, p := range company {
		got = append(got, p.Vendor)
	}
	if !slices.Equal(got, []string{"slack", "google", "microsoft"}) {
		t.Fatalf("company order = %v", got)
	}
}

// The company set runs in the wizard's vendor order: Swift's CompanyVendor
// (CompanySetupWizardModel.steps walks CompanyVendor.allCases).
func TestCompanyVendorsMatchWizardOrder(t *testing.T) {
	b, err := os.ReadFile("../../WatchtowerDesktop/Sources/WatchtowerCore/Models/CompanyVendor.swift")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?m)^\s*case ([a-z, ]+)$`).FindSubmatch(b)
	if m == nil {
		t.Fatal("no case line in CompanyVendor.swift")
	}
	var swift []string
	for _, v := range strings.Split(string(m[1]), ",") {
		swift = append(swift, strings.TrimSpace(v))
	}
	if !slices.Equal(swift, CompanyVendors) {
		t.Fatalf("CompanyVendors = %v, Swift CompanyVendor = %v", CompanyVendors, swift)
	}
}
