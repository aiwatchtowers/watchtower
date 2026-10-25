package media

import (
	"context"
	"fmt"
	"net"
	"sort"
	"strings"

	"golang.org/x/net/publicsuffix"

	"watchtower/internal/config"
	"watchtower/internal/doclinks"
	"watchtower/internal/media/linkrule"
)

// BuildDenyHosts is the build's seed of hosts whose links are never fetched,
// comma-separated, set by ldflags (`-X watchtower/internal/media.BuildDenyHosts=…`
// from WATCHTOWER_LINK_FETCH_DENY_HOSTS; the purge.BuildDefault precedent).
// Optional: the owner's company domains are refused anyway (OrgDomains, ask
// #598); a build may seed further hosts here.
var BuildDenyHosts = ""

// DenyHosts is the build seed united with the config's
// knowledge.link_fetch_deny_hosts: a config list only adds hosts, it never
// drops the seed. Normalize the result with NormalizeHostSet.
func DenyHosts(cfg *config.Config) []string {
	var out []string
	add := func(h string) {
		if h = strings.TrimSpace(h); h != "" {
			out = append(out, h)
		}
	}
	for _, h := range strings.Split(BuildDenyHosts, ",") {
		add(h)
	}
	if cfg != nil {
		for _, h := range cfg.Knowledge.LinkFetchDenyHosts {
			add(h)
		}
	}
	return out
}

// PublicMailDomains are registrable domains of public mailbox providers: an
// owner address there names no company, so OrgDomains never refuses them.
var PublicMailDomains = []string{
	"gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com",
	"yahoo.com", "ymail.com", "icloud.com", "me.com", "mac.com", "aol.com",
	"proton.me", "protonmail.com", "protonmail.ch", "pm.me", "tutanota.com", "tuta.io",
	"zoho.com", "fastmail.com", "hey.com", "mail.com", "gmx.com", "gmx.net", "web.de",
	"t-online.de", "mail.ru", "inbox.ru", "list.ru", "bk.ru", "rambler.ru", "ya.ru",
	"ukr.net", "i.ua", "meta.ua", "qq.com", "163.com", "126.com", "naver.com",
	"seznam.cz", "wp.pl", "o2.pl", "interia.pl", "libero.it", "orange.fr", "free.fr",
	"laposte.net", "comcast.net", "verizon.net", "att.net",
}

// publicMailBrands are provider names that are public under any suffix
// (gmx.de, yandex.ru, yahoo.co.uk, hotmail.fr, …): the first label of the
// registrable domain.
var publicMailBrands = map[string]bool{
	"gmail": true, "googlemail": true, "yahoo": true, "hotmail": true, "outlook": true,
	"gmx": true, "yandex": true, "aol": true,
}

var publicMailSet = func() map[string]bool {
	m := make(map[string]bool, len(PublicMailDomains))
	for _, d := range PublicMailDomains {
		m[d] = true
	}
	return m
}()

// orgDomain returns the registrable domain (eTLD+1, lowercase IDNA ASCII) of
// an email address, or false for a public mailbox provider, a domain that is
// itself a public suffix, or an address that does not parse.
func orgDomain(addr string) (string, bool) {
	at := strings.LastIndexByte(addr, '@')
	if at < 0 {
		return "", false
	}
	set := linkrule.NormalizeHostSet([]string{addr[at+1:]})
	if len(set) != 1 {
		return "", false
	}
	var host string
	for h := range set {
		host = h
	}
	if net.ParseIP(host) != nil {
		return "", false
	}
	reg, err := publicsuffix.EffectiveTLDPlusOne(host)
	if err != nil {
		return "", false
	}
	brand, _, _ := strings.Cut(reg, ".")
	if publicMailSet[reg] || publicMailBrands[brand] {
		return "", false
	}
	return reg, true
}

// OrgDomains are the registrable domains of the owner's own account
// addresses (Google, IMAP/Outlook, the Jira and Linear identities of
// accounts not removed): the company's own domains, whose links are never
// fetched in any build (ask #598). Public mailbox providers are left out.
// Sorted, without duplicates.
func OrgDomains(ctx context.Context, q doclinks.Queryer) ([]string, error) {
	rows, err := q.QueryContext(ctx, `SELECT email FROM google_accounts
		UNION SELECT email_address FROM email_accounts
		UNION SELECT owner_email FROM jira_accounts WHERE status != 'removed'
		UNION SELECT owner_email FROM linear_accounts WHERE status != 'removed'`)
	if err != nil {
		return nil, fmt.Errorf("media: listing account addresses: %w", err)
	}
	defer rows.Close()
	seen := map[string]bool{}
	var out []string
	for rows.Next() {
		var addr string
		if err := rows.Scan(&addr); err != nil {
			return nil, fmt.Errorf("media: listing account addresses: %w", err)
		}
		if d, ok := orgDomain(strings.TrimSpace(addr)); ok && !seen[d] {
			seen[d] = true
			out = append(out, d)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("media: listing account addresses: %w", err)
	}
	sort.Strings(out)
	return out, nil
}

// RefusedHosts is the refused-host set Fetchable takes, read afresh: the
// synced sources, the connected Jira/Confluence sites, the owner's own
// company domains (OrgDomains) and deny (DenyHosts). Discovery and the pass
// build it the same way.
func RefusedHosts(ctx context.Context, q doclinks.Queryer, deny []string) (map[string]bool, error) {
	sites, err := doclinks.SiteHosts(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("media: %w", err)
	}
	org, err := OrgDomains(ctx, q)
	if err != nil {
		return nil, err
	}
	hosts := append([]string{}, linkrule.SyncedHosts...)
	for h := range sites {
		hosts = append(hosts, h)
	}
	hosts = append(hosts, org...)
	return linkrule.NormalizeHostSet(append(hosts, deny...)), nil
}
