package providerrouting

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/llmusage"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providers"
	"watchtower/internal/sessions"
)

type fakeLeaf struct {
	call func(context.Context, string, string, string) (string, *digest.Usage, string, error)
}

func (f *fakeLeaf) Generate(c context.Context, s, u, id string) (string, *digest.Usage, string, error) {
	return f.call(c, s, u, id)
}

type fakeImage struct{ *fakeLeaf }

func (f fakeImage) GenerateWithImage(c context.Context, s, u, path, media string) (string, *digest.Usage, error) {
	text, usage, _, err := f.Generate(c, s, u, "")
	return text, usage, err
}
func routeConfig() *config.Config {
	cfg := &config.Config{}
	cfg.AI.Provider = "claude"
	cfg.AI.ConfiguredProvider = "claude"
	cfg.AI.Fallback = config.AIFallbackConfig{Enabled: true, Provider: "codex"}
	cfg.AI.Providers = map[string]config.AIProviderConfig{"claude": {Models: config.AIModels{Light: "haiku", Strong: "opus"}}, "codex": {Models: config.AIModels{Light: "gpt-light", Strong: "gpt-strong"}}}
	return cfg
}
func TestLegacyOffPinnedAutomationAndTransparentTier(t *testing.T) {
	for _, variant := range []string{"off", "pin", "automation", "automation_source", "light", "strong"} {
		t.Run(variant, func(t *testing.T) {
			cfg := routeConfig()
			ctx := context.Background()
			legacyCalls, calls := 0, 0
			legacy := &fakeLeaf{call: func(context.Context, string, string, string) (string, *digest.Usage, string, error) {
				legacyCalls++
				return "legacy", nil, "old-session", quota("claude")
			}}
			opts := GeneratorOptions{Router: &Router{Allowed: func(string) error { return nil }}}
			switch variant {
			case "off":
				cfg.AI.Fallback.Enabled = false
			case "pin":
				opts.Pinned = true
			case "automation":
				ctx = llmusage.WithAutomation(ctx, 1, 2)
			case "automation_source":
				ctx = digest.WithSource(ctx, "automation.llm")
			case "light":
				ctx = digest.WithSource(ctx, "digest.channel_batch")
			case "strong":
				ctx = digest.WithSource(ctx, "coach.propose")
			}
			factory := func(p string) digest.Generator {
				return &fakeLeaf{call: func(c context.Context, _, _, session string) (string, *digest.Usage, string, error) {
					calls++
					if session != "" {
						t.Fatal("session crossed providers")
					}
					source, _ := digest.SourceFromContext(c)
					if source == "" {
						t.Fatal("lost source")
					}
					return "ok", nil, "new-session", nil
				}}
			}
			gen := WrapGenerator(cfg, legacy, factory, opts)
			text, _, _, err := gen.Generate(ctx, "system", "user", "old-session")
			if variant == "light" || variant == "strong" {
				if err != nil || text != "ok" || calls != 1 || legacyCalls != 0 {
					t.Fatal(text, err, calls, legacyCalls)
				}
			} else if err == nil || text != "legacy" || legacyCalls != 1 || calls != 0 {
				t.Fatal(text, err, calls, legacyCalls)
			}
			if (variant == "off" || variant == "pin") && gen != legacy {
				t.Fatal("off/pinned did not retain exact legacy path")
			}
		})
	}
}
func TestGeneratorImagesAndActualPerProviderTier(t *testing.T) {
	cfg := routeConfig()
	r := &Router{Allowed: func(string) error { return nil }}
	var attempts []Attempt
	reqHook := hook{before: func(_ context.Context, a Attempt) error { attempts = append(attempts, a); return nil }}
	calls := 0
	factory := func(p string) digest.Generator {
		return fakeImage{&fakeLeaf{call: func(ctx context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
			calls++
			if p == "claude" {
				return "", nil, "", quota(p)
			}
			return "image", nil, "", nil
		}}}
	}
	gen := WrapGenerator(cfg, &fakeLeaf{}, factory, GeneratorOptions{Router: r})
	image, ok := digest.ImageCapable(digest.WithCallTimeout(gen, time.Second))
	if !ok {
		t.Fatal("wrapper lost image")
	}
	text, _, err := image.GenerateWithImage(WithAttemptHook(context.Background(), reqHook), "", "", "image.png", "image/png")
	if err != nil || text != "image" || calls != 2 {
		t.Fatal(text, err, calls)
	}
	if len(attempts) != 2 || attempts[0].Model != "opus" || attempts[1].Model != "gpt-strong" {
		t.Fatal(attempts)
	}
	attempts = nil
	_, _, _, err = gen.Generate(WithAttemptHook(digest.WithSource(context.Background(), "digest.channel_batch"), reqHook), "", "", "")
	if err != nil || len(attempts) != 2 || attempts[0].Model != "haiku" || attempts[1].Model != "gpt-light" {
		t.Fatal(attempts, err)
	}
}
func TestPooledRouteKnownQuotaDoesNotWaitForWorker(t *testing.T) {
	cfg := routeConfig()
	store := providerhealth.New(t.TempDir(), nil)
	for _, p := range []string{"claude", "codex"} {
		if err := store.RecordQuota(context.Background(), providerhealth.AccountScope(p, ""), &providers.Failure{Provider: p, Category: providers.Quota}); err != nil {
			t.Fatal(err)
		}
	}
	pool := sessions.NewSessionPool(1)
	t.Cleanup(pool.Close)
	worker, err := pool.Acquire(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Release(worker)
	factory := func(string) digest.Generator {
		return digest.NewPooledGenerator(&fakeLeaf{call: func(context.Context, string, string, string) (string, *digest.Usage, string, error) {
			t.Fatal("synthetic model call")
			return "", nil, "", nil
		}}, pool)
	}
	gen := WrapGenerator(cfg, &fakeLeaf{}, factory, GeneratorOptions{Router: &Router{Health: store, Allowed: func(string) error { return nil }}, Timeout: time.Second})
	_, _, _, err = gen.Generate(context.Background(), "", "", "")
	if !errors.Is(err, ErrDeferred) {
		t.Fatal(err)
	}
}
func TestSharedPoolLimitAndDeadlineIncludesQueue(t *testing.T) {
	cfg := routeConfig()
	pool := sessions.NewSessionPool(1)
	t.Cleanup(pool.Close)
	worker, err := pool.Acquire(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	var mu sync.Mutex
	factory := func(p string) digest.Generator {
		return digest.NewPooledGenerator(&fakeLeaf{call: func(context.Context, string, string, string) (string, *digest.Usage, string, error) {
			mu.Lock()
			calls++
			mu.Unlock()
			return "ok", nil, "", nil
		}}, pool)
	}
	gen := WrapGenerator(cfg, &fakeLeaf{}, factory, GeneratorOptions{Router: &Router{Allowed: func(string) error { return nil }}, Timeout: 20 * time.Millisecond})
	_, _, _, err = gen.Generate(context.Background(), "", "", "")
	pool.Release(worker)
	if !errors.Is(err, context.DeadlineExceeded) || calls != 0 {
		t.Fatal(err, calls)
	}
}

func TestBothLeavesShareOneConcurrencyLimit(t *testing.T) {
	pool := sessions.NewSessionPool(1)
	t.Cleanup(pool.Close)
	var mu sync.Mutex
	active, peak, total := 0, 0, 0
	factory := func(p string) digest.Generator {
		return digest.NewPooledGenerator(&fakeLeaf{call: func(ctx context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
			mu.Lock()
			active++
			total++
			if active > peak {
				peak = active
			}
			mu.Unlock()
			timer := time.NewTimer(time.Millisecond)
			defer timer.Stop()
			select {
			case <-ctx.Done():
			case <-timer.C:
			}
			mu.Lock()
			active--
			mu.Unlock()
			if p == "claude" {
				return "", nil, "", quota(p)
			}
			return "ok", nil, "", nil
		}}, pool)
	}
	gen := WrapGenerator(routeConfig(), &fakeLeaf{}, factory, GeneratorOptions{Router: &Router{Allowed: func(string) error { return nil }}, Timeout: time.Second})
	var wg sync.WaitGroup
	for range 6 {
		wg.Go(func() {
			if _, _, _, err := gen.Generate(context.Background(), "", "", ""); err != nil {
				t.Error(err)
			}
		})
	}
	wg.Wait()
	if peak != 1 || total != 12 {
		t.Fatal(peak, total)
	}
}

// A raw cliGenerator caller such as chat.title has no context deadline. The
// adapter must supply the total bound that makes its due recovery probe valid.
func TestRawRouteDefaultDeadlineRecoversDueCircuits(t *testing.T) {
	for _, imageCall := range []bool{false, true} {
		for _, shortParent := range []bool{false, true} {
			name := "text"
			if imageCall {
				name = "image"
			}
			if shortParent {
				name += "/parent_deadline"
			}
			t.Run(name, func(t *testing.T) {
				now := time.Now().Add(-6 * time.Minute)
				store := providerhealth.New(t.TempDir(), func() time.Time { return now })
				for _, provider := range []string{"claude", "codex"} {
					if err := store.RecordQuota(context.Background(), providerhealth.AccountScope(provider, ""), &providers.Failure{Provider: provider, Category: providers.Quota}); err != nil {
						t.Fatal(err)
					}
				}
				now = time.Now()
				r := &Router{Health: store, Now: func() time.Time { return now }, Allowed: func(string) error { return nil }}
				ctx := context.Background()
				var parentDeadline time.Time
				if shortParent {
					var cancel context.CancelFunc
					ctx, cancel = context.WithTimeout(ctx, time.Second)
					defer cancel()
					parentDeadline, _ = ctx.Deadline()
				}
				calls := 0
				started := time.Now()
				factory := func(provider string) digest.Generator {
					return fakeImage{&fakeLeaf{call: func(ctx context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
						calls++
						if provider != "claude" {
							t.Fatal("reserve called instead of due preferred probe")
						}
						deadline, ok := ctx.Deadline()
						if !ok {
							t.Fatal("unbounded enabled raw route")
						}
						if shortParent {
							if !deadline.Equal(parentDeadline) {
								t.Fatal("caller deadline extended", deadline, parentDeadline)
							}
						} else if deadline.Before(started.Add(digest.DaemonAICallTimeout-time.Second)) || deadline.After(time.Now().Add(digest.DaemonAICallTimeout)) {
							t.Fatal("incorrect default total bound", deadline)
						}
						state, err := store.Read(context.Background(), providerhealth.AccountScope(provider, ""))
						if err != nil || state.State != providerhealth.ProbeLeased {
							t.Fatal("real safe request did not own recovery lease", state, err)
						}
						return "recovered", nil, "", nil
					}}}
				}
				gen := WrapGenerator(routeConfig(), &fakeLeaf{}, factory, GeneratorOptions{Router: r})
				var text string
				var err error
				if imageCall {
					image, ok := digest.ImageCapable(gen)
					if !ok {
						t.Fatal("image capability lost")
					}
					text, _, err = image.GenerateWithImage(ctx, "", "request", "image.png", "image/png")
				} else {
					text, _, _, err = gen.Generate(ctx, "", "request", "")
				}
				if err != nil || text != "recovered" || calls != 1 {
					t.Fatal(text, err, calls)
				}
				preferred, err := store.Read(context.Background(), providerhealth.AccountScope("claude", ""))
				if err != nil || preferred.State != providerhealth.Available {
					t.Fatal(preferred, err)
				}
				reserve, err := store.Read(context.Background(), providerhealth.AccountScope("codex", ""))
				if err != nil || reserve.State != providerhealth.QuotaWait {
					t.Fatal("unused reserve circuit changed", reserve, err)
				}
			})
		}
	}
}

func TestRawRouteDefaultBoundLeavesLegacyContextsUnchanged(t *testing.T) {
	for _, variant := range []string{"off", "pin", "automation", "automation_source"} {
		t.Run(variant, func(t *testing.T) {
			cfg := routeConfig()
			opts := GeneratorOptions{Router: &Router{Allowed: func(string) error { return nil }}}
			ctx := context.Background()
			switch variant {
			case "off":
				cfg.AI.Fallback.Enabled = false
			case "pin":
				opts.Pinned = true
			case "automation":
				ctx = llmusage.WithAutomation(ctx, 1, 2)
			case "automation_source":
				ctx = digest.WithSource(ctx, "automation.llm")
			}
			calls := 0
			legacy := fakeImage{&fakeLeaf{call: func(c context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
				calls++
				if _, ok := c.Deadline(); ok {
					t.Fatal("default routing bound changed legacy context")
				}
				return "legacy", nil, "", nil
			}}}
			gen := WrapGenerator(cfg, legacy, func(string) digest.Generator { t.Fatal("legacy path constructed a routed leaf"); return nil }, opts)
			if _, _, _, err := gen.Generate(ctx, "", "", ""); err != nil {
				t.Fatal(err)
			}
			if _, _, err := gen.(digest.ImageGenerator).GenerateWithImage(ctx, "", "", "image.png", "image/png"); err != nil {
				t.Fatal(err)
			}
			if calls != 2 {
				t.Fatal(calls)
			}
		})
	}
}
