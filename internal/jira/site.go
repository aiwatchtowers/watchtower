package jira

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// ErrNotAtlassianCloud is ValidateCloudSite's refusal: the site is not an
// Atlassian Cloud site, so no client secret, token or credential is ever sent
// on its word.
var ErrNotAtlassianCloud = errors.New("not an Atlassian Cloud site")

// cloudSiteSuffix is the host suffix of every standard Atlassian Cloud site.
const cloudSiteSuffix = ".atlassian.net"

// tenantInfoMaxBytes caps the _edge/tenant_info answer (a few dozen bytes).
const tenantInfoMaxBytes = 16 << 10

// ValidateCloudSite checks that site (an https origin, as a company bundle
// carries it) is an Atlassian Cloud site: a host under .atlassian.net passes
// without a request; any other host must answer GET
// https://<host>/_edge/tenant_info with a cloudId (Atlassian Cloud's custom
// domains do). That request carries no credential and follows no redirect.
// hc nil uses a 15 s client. A site that is not is ErrNotAtlassianCloud; a
// probe that could not run (network) is another error — a refusal as well.
func ValidateCloudSite(ctx context.Context, hc *http.Client, site string) error {
	u, err := url.Parse(site)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil ||
		u.RawQuery != "" || u.Fragment != "" || strings.Trim(u.Path, "/") != "" {
		return fmt.Errorf("%w: %q is not an https site address", ErrNotAtlassianCloud, site)
	}
	host := strings.ToLower(u.Hostname())
	if u.Port() == "" && strings.HasSuffix(host, cloudSiteSuffix) && len(host) > len(cloudSiteSuffix) &&
		!strings.Contains(strings.TrimSuffix(host, cloudSiteSuffix), ".") {
		return nil
	}
	return checkTenantInfo(ctx, hc, u)
}

// checkTenantInfo asks the host for its Atlassian tenant.
func checkTenantInfo(ctx context.Context, hc *http.Client, u *url.URL) error {
	if hc == nil {
		hc = &http.Client{Timeout: 15 * time.Second}
	}
	noRedirect := *hc
	noRedirect.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	probe := url.URL{Scheme: "https", Host: u.Host, Path: "/_edge/tenant_info"}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, probe.String(), nil)
	if err != nil {
		return err
	}
	resp, err := noRedirect.Do(req)
	if err != nil {
		// Not a verdict on the site: the check could not run. Still a refusal.
		return fmt.Errorf("checking that %s is Atlassian Cloud: %w", u.Host, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%w: %s answered %d", ErrNotAtlassianCloud, u.Host, resp.StatusCode)
	}
	var info struct {
		CloudID string `json:"cloudId"`
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, tenantInfoMaxBytes))
	if err != nil {
		return fmt.Errorf("checking that %s is Atlassian Cloud: %w", u.Host, err)
	}
	if json.Unmarshal(body, &info) != nil || strings.TrimSpace(info.CloudID) == "" {
		return fmt.Errorf("%w: %s has no Atlassian tenant", ErrNotAtlassianCloud, u.Host)
	}
	return nil
}
