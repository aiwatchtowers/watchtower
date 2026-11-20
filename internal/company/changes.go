package company

import "watchtower/internal/companybundle"

// Change is one client value a bundle changes for a vendor the stored bundle
// already had. Old and New are empty for a secret (never shown); New is empty
// when the incoming bundle drops the vendor.
type Change struct {
	Vendor string
	Field  string
	Old    string
	New    string
}

// field is one compared value of a vendor block.
type field struct {
	name   string
	secret bool
	value  string
}

// vendorFields are the compared values of each vendor block (nil block → nil):
// client ids, secrets, the Microsoft tenant and the Atlassian site. Domain,
// Confluence and the deny hosts change nothing an account signed in with.
func vendorFields(b companybundle.Bundle, vendor string) []field {
	switch vendor {
	case "slack":
		if b.Slack != nil {
			return []field{{name: "client_id", value: b.Slack.ClientID}}
		}
	case "google":
		if b.Google != nil {
			return []field{{name: "client_id", value: b.Google.ClientID}, {name: "client_secret", secret: true, value: b.Google.ClientSecret}}
		}
	case "atlassian":
		if b.Atlassian != nil {
			return []field{
				{name: "client_id", value: b.Atlassian.ClientID},
				{name: "client_secret", secret: true, value: b.Atlassian.ClientSecret},
				{name: "site", value: b.Atlassian.Site},
			}
		}
	case "microsoft":
		if b.Microsoft != nil {
			return []field{{name: "client_id", value: b.Microsoft.ClientID}, {name: "tenant_id", value: b.Microsoft.TenantID}}
		}
	case "linear":
		if b.Linear != nil {
			return []field{{name: "client_id", value: b.Linear.ClientID}}
		}
	}
	return nil
}

// vendorOrder is companybundle.Bundle.Vendors' order.
var vendorOrder = []string{"slack", "google", "atlassian", "microsoft", "linear"}

// Changes lists what incoming changes in the clients stored already had, in
// vendor order. A vendor incoming adds is no change; a vendor it drops is
// (its accounts would lose their client). Both bundles come out of
// companybundle's parsers, so a difference in form only (site case, a
// trailing slash, spaces around an id) is no change.
func Changes(stored, incoming companybundle.Bundle) []Change {
	var out []Change
	for _, v := range vendorOrder {
		old := vendorFields(stored, v)
		if old == nil {
			continue
		}
		cur := vendorFields(incoming, v)
		for i, f := range old {
			n := ""
			if cur != nil {
				n = cur[i].value
			}
			if n == f.value {
				continue
			}
			c := Change{Vendor: v, Field: f.name, Old: f.value, New: n}
			if f.secret {
				c.Old, c.New = "", ""
			}
			out = append(out, c)
		}
	}
	return out
}

// ShortID shortens an id for the Replace warning (A21): its first 4 and last
// 3 characters around "…"; an id of 7 characters or fewer stays whole.
func ShortID(id string) string {
	r := []rune(id)
	if len(r) <= 7 {
		return id
	}
	return string(r[:4]) + "…" + string(r[len(r)-3:])
}
