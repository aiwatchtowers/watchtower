package diagnostics

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/spf13/viper"

	"watchtower/internal/config"
	"watchtower/internal/features"
	"watchtower/internal/providers/caps"
)

// envAIProvider is the variable that overrides ai.provider (viper's
// WATCHTOWER prefix + the "."→"_" replacer, as config.Load binds it).
const envAIProvider = "WATCHTOWER_AI_PROVIDER"

// Env is what the config, workspace, AI and features lines read from the
// process: the --config path (flagConfig; "" when there is no home
// directory and no WATCHTOWER_CONFIG_PATH), the global --workspace flag, an
// environment reader and the data-root resolver. Nil Getenv / DataRoot use
// os.Getenv / config.DataRoot.
type Env struct {
	ConfigPath    string
	WorkspaceFlag string
	Getenv        func(string) string
	DataRoot      func() (string, error)
}

func (e Env) getenv(k string) string {
	if e.Getenv == nil {
		return os.Getenv(k)
	}
	return e.Getenv(k)
}

func (e Env) dataRoot() (string, error) {
	if e.DataRoot == nil {
		return config.DataRoot()
	}
	return e.DataRoot()
}

// ConfigState is the outcome of reading the config file.
type ConfigState int

const (
	ConfigStateOK ConfigState = iota
	ConfigStateNone
	ConfigStateInvalid
	ConfigStateUnreadable
	ConfigStateNoHome
)

// Resolved is the result of the four resolution steps (config path, config
// load, data root, workspace), stopping at the first failure. Every text is
// the part after its label (LabelConfig, LabelWorkspace): the runner's Slot
// prints the label.
type Resolved struct {
	Cfg         *config.Config // nil unless ConfigState == ConfigStateOK
	ConfigLine  string
	ConfigState ConfigState
	Root        string // data root; "" when not resolved
	Workspace   string // workspace name; "" when not resolved (never printed)
	// WorkspaceLine is the Workspace: line's text, "" when a workspace
	// resolves or when an earlier step already failed (no line then).
	WorkspaceLine string
	// WorkspaceReason is the `unknown (…)` text every workspace-dependent
	// part prints; "" when a workspace resolves.
	WorkspaceReason string
}

// Resolve runs the steps of the spec's "Paths without a fatal helper": it
// never calls config.WorkspaceDir / DBPath (they log.Fatalf without a home
// directory) and never writes anything.
func Resolve(env Env) Resolved {
	if env.ConfigPath == "" {
		return Resolved{ConfigLine: UnknownNoHome, ConfigState: ConfigStateNoHome, WorkspaceReason: UnknownNoHome}
	}
	if _, err := os.Stat(env.ConfigPath); errors.Is(err, fs.ErrNotExist) {
		return Resolved{ConfigLine: ConfigNone, ConfigState: ConfigStateNone, WorkspaceReason: UnknownNoConfig}
	}
	cfg, err := config.Load(env.ConfigPath)
	if err != nil {
		line, state := classifyConfigError(err)
		return Resolved{ConfigLine: line, ConfigState: state, WorkspaceReason: UnknownNoConfig}
	}
	r := Resolved{Cfg: cfg, ConfigLine: ConfigOK, ConfigState: ConfigStateOK}

	root, err := env.dataRoot()
	if err != nil {
		r.WorkspaceLine, r.WorkspaceReason = UnknownNoHome, UnknownNoHome
		return r
	}
	r.Root = root

	name := cfg.ActiveWorkspace
	if env.WorkspaceFlag != "" {
		name = env.WorkspaceFlag
	}
	if name == "" {
		// config.Load picks the only workspace holding a database and leaves
		// the name empty for none or several; count them, never name them.
		found, err := config.WorkspaceDirsWithDatabase(root)
		switch {
		case err != nil:
			return r.noWorkspace(WorkspaceLookupFailed)
		case len(found) == 0:
			return r.noWorkspace(WorkspaceNoneYet)
		case len(found) > 1:
			return r.noWorkspace(WorkspaceNotChosen(len(found)))
		}
		name = found[0]
	}
	if !config.ValidWorkspaceRe.MatchString(name) {
		return r.noWorkspace(WorkspaceInvalidName)
	}
	info, err := os.Stat(filepath.Join(root, name))
	switch {
	case errors.Is(err, fs.ErrNotExist), err == nil && !info.IsDir():
		return r.noWorkspace(WorkspaceNotFound)
	case err != nil:
		return r.noWorkspace(WorkspaceLookupFailed)
	}
	r.Workspace = name
	return r
}

func (r Resolved) noWorkspace(line string) Resolved {
	r.WorkspaceLine, r.WorkspaceReason = line, UnknownNoWorkspace
	return r
}

// classifyConfigError maps a config.Load error to the Config: line without
// ever printing its text.
func classifyConfigError(err error) (string, ConfigState) {
	var invalid *config.InvalidValueError
	var parse viper.ConfigParseError
	switch {
	case errors.As(err, &invalid):
		return ConfigUnreadableInvalidValue, ConfigStateInvalid
	case errors.As(err, &parse):
		return ConfigUnreadableParse, ConfigStateUnreadable
	case errors.Is(err, fs.ErrPermission):
		return ConfigUnreadablePermission, ConfigStateUnreadable
	default:
		return ConfigUnreadableOther, ConfigStateUnreadable
	}
}

// rawAI is the AI section read the way config.Load reads it (file + the
// WATCHTOWER_ env override), without Validate.
type rawAI struct {
	provider        string // effective preferred id; "" = default claude
	inFile          bool   // ai.provider set to a non-empty value in the file
	fallback        string
	fallbackEnabled bool
	buckets         []string
}

func readRawAI(path string) (rawAI, error) {
	v := viper.New()
	v.SetConfigFile(path)
	if err := v.ReadInConfig(); err != nil {
		return rawAI{}, err
	}
	inFile := v.InConfig("ai.provider") && v.GetString("ai.provider") != ""
	v.SetEnvPrefix("WATCHTOWER")
	v.AutomaticEnv()
	v.SetEnvKeyReplacer(strings.NewReplacer(".", "_"))
	r := rawAI{
		provider:        v.GetString("ai.provider"),
		inFile:          inFile,
		fallback:        v.GetString("ai.fallback.provider"),
		fallbackEnabled: v.GetBool("ai.fallback.enabled"),
	}
	for id := range v.GetStringMap("ai.providers") {
		r.buckets = append(r.buckets, id)
	}
	return r, nil
}

// providerName maps a known provider id to its printed name and its form
// option; ok is false for an unknown id.
func providerName(id string) (name, option string, ok bool) {
	switch id {
	case "", config.DefaultAIProvider:
		return ProviderClaude, ProviderClaude, true
	case "codex":
		return ProviderCodex, ProviderCodex, true
	case "ollama":
		return ProviderOllama, ProviderOllamaOption, true
	}
	return "", "", false
}

// AILine returns the AI: line's text (after LabelAI) and the JSON
// `provider` form option, per the spec's table "AI line by config state".
// A raw provider value is never printed.
func AILine(env Env, r Resolved) (text, jsonProvider string) {
	switch r.ConfigState {
	case ConfigStateNoHome:
		return UnknownNoHome, ""
	case ConfigStateNone:
		return AINotSetUp, ProviderNotSetUpOption
	case ConfigStateUnreadable:
		return UnknownNoConfig, ""
	case ConfigStateInvalid:
		return invalidAILine(env)
	case ConfigStateOK:
	}
	ai := r.Cfg.AI
	raw, rawErr := readRawAI(env.ConfigPath)
	name, option, _ := providerName(ai.ConfiguredProviderID())
	first := name + providerOrigin(env, raw, rawErr == nil)
	return JoinParts(first, reservePart(ai.Fallback.Provider, ai.Fallback.Enabled)), option
}

// providerOrigin is the suffix after the provider name: from the
// environment, chosen in the file (no suffix), or the default. A raw read
// that failed after config.Load succeeded leaves the suffix out.
func providerOrigin(env Env, raw rawAI, rawOK bool) string {
	switch {
	case env.getenv(envAIProvider) != "":
		return AIFromEnvironment
	case !rawOK || raw.inFile:
		return ""
	default:
		return AIDefaultNotChosen
	}
}

func reservePart(provider string, enabled bool) string {
	if provider == "" {
		return ""
	}
	name, _, _ := providerName(provider)
	mode := ReserveOff
	if enabled {
		mode = ReserveAutomatic
	}
	return Reserve(name, mode)
}

// invalidAILine is the AI line of a config whose AI section Validate
// rejected: the preferred provider when known, then which part was invalid.
func invalidAILine(env Env) (string, string) {
	raw, err := readRawAI(env.ConfigPath)
	if err != nil {
		return UnknownNoConfig, ""
	}
	preferred := raw.provider
	if preferred == "" {
		preferred = config.DefaultAIProvider
	}
	first, option := AIUnknownProvider, ""
	if name, opt, ok := providerName(preferred); ok {
		first, option = name+providerOrigin(env, raw, true), opt
	}
	reserve := reservePart(raw.fallback, raw.fallbackEnabled)
	if reserveInvalid(preferred, raw.fallback, raw.fallbackEnabled) {
		reserve = AIReserveInvalid
	}
	settings := ""
	if slices.ContainsFunc(raw.buckets, func(id string) bool { return !config.KnownAIProvider(id) }) {
		settings = AIProviderSettingsInvalid
	}
	return JoinParts(first, reserve, settings), option
}

// reserveInvalid applies AIConfig.Validate's fallback rules on their own,
// so a bad reserve is reported even when the preferred provider is also
// unknown.
func reserveInvalid(preferred, reserve string, enabled bool) bool {
	if reserve != "" {
		if !config.KnownAIProvider(reserve) || reserve == preferred {
			return true
		}
		if c, ok := caps.For(reserve); !ok || c.ReservePeer == "" {
			return true
		}
	}
	return enabled && (reserve == "" || !caps.Pairs(preferred, reserve))
}

// FeaturesLine returns the Features on: line's text (after LabelFeatures):
// the ids of the enabled toggleable features in registry order, as
// `features list` evaluates them. On a legacy install the daemon has not
// migrated yet (no features.migrated marker, digest.enabled false) the
// legacy mapping is applied to a copy in memory and the line says so;
// nothing is written.
func FeaturesLine(r Resolved, env Env) string {
	switch r.ConfigState {
	case ConfigStateOK:
	case ConfigStateNoHome:
		return UnknownNoHome
	default:
		return UnknownNoConfig
	}
	pending, legacy, err := config.FeatureMigrationPending(env.ConfigPath)
	if err != nil {
		return UnknownNoConfig
	}
	cfg := *r.Cfg
	suffix := ""
	if pending && legacy {
		config.ApplyLegacyDigestOff(&cfg)
		suffix = FeaturesNotMigrated
	}
	var on []string
	for _, f := range features.All() {
		if !f.Core && f.Enabled != nil && f.Enabled(&cfg) {
			on = append(on, f.ID)
		}
	}
	if len(on) == 0 {
		return FeaturesNone + suffix
	}
	return strings.Join(on, ", ") + suffix
}
