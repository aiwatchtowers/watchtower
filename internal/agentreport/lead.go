package agentreport

import "math"

// leads writes the one plain sentence of each block (context, skills,
// trouble) in lang. It is built from the block's counts, part names, error
// classes and tool names only; an empty block has no sentence.
func leads(lang Lang, c ContextReport, s SkillsReport, t TroubleReport) (string, string, string) {
	return contextLead(lang, c), skillsLead(lang, s), troubleLead(lang, t)
}

func contextLead(l Lang, c ContextReport) string {
	b := c.Baseline
	if c.FactsSessions == 0 || len(b.Parts) == 0 {
		return ""
	}
	pct := func(p PartShare) int { return int(math.Round(p.Share * 100)) }
	p1 := b.Parts[0]
	if len(b.Parts) == 1 {
		return l.f("lead.context.one", l.tok(b.Tokens), partName(l, p1.Part), pct(p1))
	}
	p2 := b.Parts[1]
	return l.f("lead.context", l.tok(b.Tokens), partName(l, p1.Part), pct(p1), partName(l, p2.Part), pct(p2))
}

// partName is the baseline part's human name; an unknown one (a newer CLI) as stored.
func partName(l Lang, part string) string {
	if _, ok := msgs["lead.part."+part]; !ok {
		return part
	}
	return l.f("lead.part." + part)
}

func skillsLead(l Lang, s SkillsReport) string {
	if s.Listed == 0 {
		return ""
	}
	return l.f("lead.skills", l.tok(s.ListingTokens), max(s.Listed-s.Used, 0), s.Listed)
}

func troubleLead(l Lang, t TroubleReport) string {
	failed, denied := 0, 0
	top, topN := "", 0
	for _, c := range t.Classes { // largest first
		failed += c.Count
		if c.Count > topN {
			top, topN = c.Class, c.Count
		}
	}
	for _, d := range t.denials { // uncut
		denied += d.Count
	}
	if len(t.denials) > 0 && t.denials[0].Count > topN { // largest first
		top = t.denials[0].Tool
	}
	if failed == 0 && denied == 0 {
		return ""
	}
	out := l.f("lead.trouble", l.count(failed, "call.failed"), l.count(denied, "denial.perm"))
	if top != "" {
		out += l.f("lead.trouble.top", top)
	}
	return out + "."
}
