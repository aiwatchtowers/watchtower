package cmd

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"watchtower/internal/auth"
	"watchtower/internal/config"
	"watchtower/internal/db"

	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

var authCmd = &cobra.Command{
	Use:   "auth",
	Short: "Authenticate with Slack via OAuth",
}

var authLoginCmd = &cobra.Command{
	Use:   "login",
	Short: "Log in to Slack via browser-based OAuth flow",
	Long: `Starts a browser-based OAuth flow to obtain a Slack user token.

Uses the built-in Watchtower Slack app by default. Override with
WATCHTOWER_OAUTH_CLIENT_ID and WATCHTOWER_OAUTH_CLIENT_SECRET env vars.`,
	RunE: runAuthLogin,
}

var authPrepareCmd = &cobra.Command{
	Use:   "prepare",
	Short: "Generate OAuth authorization URL for in-app login",
	Long:  `Outputs a JSON object with authorize_url, redirect_uri, and state for the desktop app to use in a WKWebView-based OAuth flow.`,
	RunE:  runAuthPrepare,
}

var authCompleteCmd = &cobra.Command{
	Use:   "complete",
	Short: "Exchange OAuth authorization code for token",
	Long:  `Exchanges an OAuth code (obtained from the in-app WKWebView callback) for a Slack user token and saves it to config.`,
	RunE:  runAuthComplete,
}

var authLogoutCmd = &cobra.Command{
	Use:   "logout",
	Short: "Disconnect account #1's Slack workspace (non-destructive: keeps synced data)",
	Long: `Legacy alias for "slack remove" on account #1: deletes the account's stored
OAuth token and marks it removed so it stops syncing. Its synced messages,
channels, digests, tracks, situations, and memory are deliberately kept —
this is a soft delete, not a purge. Use "slack accounts"/"slack remove <id>"
for multi-account control.`,
	RunE: runAuthLogout,
}

var authTrustCertCmd = &cobra.Command{
	Use:   "trust-cert",
	Short: "Trust the localhost HTTPS certificate (one-time macOS setup)",
	Long: `Generates a persistent localhost TLS certificate (if needed) and adds it
to the macOS user trust store. This triggers a system authorization dialog
(Touch ID or password). After this, localhost HTTPS works without browser warnings.`,
	RunE: runAuthTrustCert,
}

var authCheckCertCmd = &cobra.Command{
	Use:   "check-cert",
	Short: "Check if the localhost certificate is trusted",
	RunE:  runAuthCheckCert,
}

func init() {
	rootCmd.AddCommand(authCmd)
	authCmd.AddCommand(authLoginCmd)
	authCmd.AddCommand(authLogoutCmd)
	authCmd.AddCommand(authPrepareCmd)
	authCmd.AddCommand(authCompleteCmd)
	authCmd.AddCommand(authTrustCertCmd)
	authCmd.AddCommand(authCheckCertCmd)

	authCompleteCmd.Flags().String("code", "", "OAuth authorization code from Slack callback")
	authCompleteCmd.Flags().String("redirect-uri", "", "Redirect URI used in the authorize request")
	_ = authCompleteCmd.MarkFlagRequired("code")
	_ = authCompleteCmd.MarkFlagRequired("redirect-uri")

	authPrepareCmd.Flags().String("redirect-uri", "", "Custom redirect URI (e.g. watchtower-auth://callback for desktop app)")

	authLoginCmd.Flags().Bool("no-open", false, "Don't open the browser automatically (print the URL instead)")
}

func runAuthLogin(cmd *cobra.Command, _ []string) error {
	oauthCfg, err := resolveOAuthConfig()
	if err != nil {
		return err
	}

	noOpen, _ := cmd.Flags().GetBool("no-open")
	out := cmd.OutOrStdout()
	result, err := auth.Login(cmd.Context(), oauthCfg, out, auth.LoginOptions{SkipBrowserOpen: noOpen})
	if err != nil {
		return fmt.Errorf("oauth login: %w", err)
	}

	info, err := saveAuthResult(cmd, result)
	if err != nil {
		return err
	}

	// H1: auth login prints human-readable text only (no JSON)
	fmt.Fprintf(out, "\nLogged in to workspace %q (team: %s, user: %s)\n", info.Workspace, info.TeamID, info.UserID)
	fmt.Fprintf(out, "Config written to: %s\n", flagConfig)
	fmt.Fprintf(out, "Run 'watchtower sync' to start syncing.\n")

	return nil
}

func runAuthPrepare(cmd *cobra.Command, _ []string) error {
	cfg, err := resolveOAuthConfig()
	if err != nil {
		return err
	}

	redirectURI, _ := cmd.Flags().GetString("redirect-uri")
	result, err := auth.Prepare(cfg, redirectURI)
	if err != nil {
		return fmt.Errorf("auth prepare: %w", err)
	}

	return json.NewEncoder(os.Stdout).Encode(result)
}

func runAuthTrustCert(_ *cobra.Command, _ []string) error {
	// Ensure cert exists (generates if needed)
	if _, err := auth.EnsureCert(); err != nil {
		return fmt.Errorf("generating certificate: %w", err)
	}

	if auth.IsCertTrusted() {
		fmt.Println("Certificate is already trusted.")
		return nil
	}

	fmt.Println("Adding localhost certificate to macOS trust store...")
	if err := auth.TrustCert(); err != nil {
		return err
	}
	fmt.Println("Done! Localhost HTTPS will now work without browser warnings.")
	return nil
}

func runAuthCheckCert(_ *cobra.Command, _ []string) error {
	if _, err := auth.EnsureCert(); err != nil {
		return fmt.Errorf("generating certificate: %w", err)
	}
	if auth.IsCertTrusted() {
		fmt.Println("trusted")
	} else {
		fmt.Println("untrusted")
	}
	return nil
}

func runAuthComplete(cmd *cobra.Command, _ []string) error {
	cfg, err := resolveOAuthConfig()
	if err != nil {
		return err
	}

	code, _ := cmd.Flags().GetString("code")
	redirectURI, _ := cmd.Flags().GetString("redirect-uri")
	result, err := auth.Complete(cmd.Context(), cfg, code, redirectURI)
	if err != nil {
		return fmt.Errorf("auth complete: %w", err)
	}

	// H1: auth complete outputs JSON for the desktop app to parse
	info, err := saveAuthResult(cmd, result)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(info)
}

// runAuthLogout is the legacy single-account alias for `slack remove 1`: it
// disconnects account #1 (the implicit account every single-account install
// has). Non-destructive, matching the multi-account model — the token file is
// deleted and the row marked removed so it stops syncing, but synced Slack data
// is kept (use a fresh sync or `slack remove` semantics; a full purge is no
// longer part of logout). Create-if-absent does NOT apply to logout: with no
// account #1 (nothing ever connected) it is a clean no-op, matching today's
// `auth logout` with no token set.
func runAuthLogout(cmd *cobra.Command, _ []string) error {
	cfg, database, err := openSlackCmdDB(cmd)
	if err != nil {
		return err
	}
	defer database.Close()

	accounts, err := database.ListSlackAccounts()
	if err != nil {
		return fmt.Errorf("listing accounts: %w", err)
	}

	// Also blank any lingering legacy config token so a re-login starts clean
	// and the config source can never silently re-grant access.
	logger := log.New(cmd.ErrOrStderr(), "[slack] ", log.LstdFlags)
	blankLegacySlackConfigToken(cfg, logger)

	out := cmd.OutOrStdout()
	if len(accounts) == 0 {
		fmt.Fprintln(out, "No Slack account connected — nothing to disconnect.")
		return nil
	}

	id := accounts[0].ID
	if err := removeSlackAccount(cfg, database, id); err != nil {
		return fmt.Errorf("removing account: %w", err)
	}

	fmt.Fprintf(out, "Slack disconnected: account %d token removed (synced data kept).\n", id)
	fmt.Fprintln(out, "Restart the sync daemon if it is running so it stops syncing Slack.")
	return nil
}

// resolveOAuthConfig reads OAuth credentials from env or build-time defaults.
func resolveOAuthConfig() (auth.OAuthConfig, error) {
	clientID := os.Getenv("WATCHTOWER_OAUTH_CLIENT_ID")
	clientSecret := os.Getenv("WATCHTOWER_OAUTH_CLIENT_SECRET")
	if clientID == "" {
		clientID = auth.DefaultClientID
	}
	if clientSecret == "" {
		clientSecret = auth.DefaultClientSecret
	}
	if clientID == "" || clientSecret == "" {
		return auth.OAuthConfig{}, fmt.Errorf("OAuth credentials not configured. Set WATCHTOWER_OAUTH_CLIENT_ID and WATCHTOWER_OAUTH_CLIENT_SECRET environment variables, or use an official release build")
	}
	return auth.OAuthConfig{ClientID: clientID, ClientSecret: clientSecret}, nil
}

// authResultInfo holds the workspace info after saving config.
type authResultInfo struct {
	Workspace string `json:"workspace"`
	TeamID    string `json:"team_id"`
	UserID    string `json:"user_id"`
}

// saveAuthResult persists an OAuth login result onto a slack_accounts row and
// its per-account token file (slack_token_<id>.json) — NOT into config.yaml.
// It still writes the workspace scaffolding (active_workspace + sensible
// defaults) so a fresh install has a resolvable workspace/DB path, but the
// Slack token itself now lives only in the DB row + token file.
//
// Behaves as the legacy single-account alias: it seeds account #1 from any
// pre-multi-account config token, then re-consents account #1 when one already
// exists (like `slack login --account 1`) or creates it when none does (like
// `slack add` with an empty label).
func saveAuthResult(cmd *cobra.Command, result *auth.OAuthResult) (*authResultInfo, error) {
	if result.ExpiresIn > 0 {
		fmt.Fprintf(os.Stderr, "Warning: token expires in %d seconds. Token rotation is not yet supported.\n", result.ExpiresIn)
	}

	workspace := sanitizeWorkspaceName(result.TeamName)
	if workspace == "" {
		workspace = result.TeamID
	}

	configPath := flagConfig
	configDir := filepath.Dir(configPath)
	if err := os.MkdirAll(configDir, 0o700); err != nil {
		return nil, fmt.Errorf("creating config directory: %w", err)
	}

	v := viper.New()
	v.SetConfigFile(configPath)
	_ = v.ReadInConfig()

	v.Set("active_workspace", workspace)

	defaults := map[string]any{
		"ai.model":                  config.DefaultAIModel,
		"ai.context_budget":         config.DefaultAIContextBudget,
		"sync.workers":              config.DefaultSyncWorkers,
		"sync.initial_history_days": config.DefaultInitialHistDays,
		"sync.poll_interval":        config.DefaultPollInterval.String(),
		"sync.sync_threads":         config.DefaultSyncThreads,
		"sync.sync_on_wake":         config.DefaultSyncOnWake,
		"digest.enabled":            config.DefaultDigestEnabled,
		"digest.min_messages":       config.DefaultDigestMinMsgs,
	}
	for key, val := range defaults {
		if !v.IsSet(key) {
			v.Set(key, val)
		}
	}

	if err := writeConfigAtomic(v, configPath); err != nil {
		return nil, err
	}

	cfg, err := config.Load(configPath)
	if err != nil {
		return nil, fmt.Errorf("reloading config: %w", err)
	}
	cfg.ActiveWorkspace = workspace

	if err := os.MkdirAll(cfg.WorkspaceDir(), 0o700); err != nil {
		return nil, fmt.Errorf("creating database directory: %w", err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return nil, fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	logger := log.New(cmd.ErrOrStderr(), "[slack] ", log.LstdFlags)
	id, err := ensureLegacySlackAccount(cmd.Context(), cfg, database, logger)
	if err != nil {
		return nil, fmt.Errorf("seeding legacy account: %w", err)
	}
	isNewRow := false
	if id == 0 {
		id, err = database.CreateSlackAccount(db.SlackAccount{})
		if err != nil {
			return nil, fmt.Errorf("creating account: %w", err)
		}
		isNewRow = true
	}

	if _, err := connectSlackAccount(cmd.Context(), cfg, database, id, result.AccessToken, isNewRow, cmd.ErrOrStderr()); err != nil {
		return nil, err
	}

	return &authResultInfo{workspace, result.TeamID, result.UserID}, nil
}

var sanitizeRe = regexp.MustCompile(`[^a-z0-9_-]+`)

// sanitizeWorkspaceName converts a team name to a safe config key:
// lowercase, special characters replaced with hyphens.
func sanitizeWorkspaceName(name string) string {
	name = strings.ToLower(strings.TrimSpace(name))
	name = sanitizeRe.ReplaceAllString(name, "-")
	name = strings.Trim(name, "-")
	return name
}
