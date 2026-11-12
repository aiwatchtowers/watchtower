package cmd

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/llmusage"
	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/providers"
	"watchtower/internal/sessions"
)

func routingCLI(t *testing.T, p string, fail bool) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), p)
	response := `{"type":"result","subtype":"success","result":"ok","usage":{"input_tokens":11,"output_tokens":3}}`
	if p == "codex" {
		response = `{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}` + "\n" + `{"type":"turn.completed","usage":{"input_tokens":11,"output_tokens":3}}`
	}
	if fail {
		if p == "claude" {
			response = `{"type":"result","subtype":"error_during_execution","is_error":true,"error":{"type":"usage_limit_reached"},"result":"quota"}`
		} else {
			response = `{"type":"turn.failed","error":{"message":"You’ve hit your usage limit. Try again later."}}`
		}
	}
	out := filepath.Join(t.TempDir(), "response")
	if err := os.WriteFile(out, []byte(response), 0600); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'codex-cli 0.166.0'; exit; fi\ncat >/dev/null\ncat '" + out + "'\n"
	if err := os.WriteFile(bin, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	return bin
}
func TestRoutingFactoriesPhysicalLeafLedgerBothDirections(t *testing.T) {
	for _, preferred := range []string{"claude", "codex"} {
		for _, factory := range []string{"cli", "bounded", "pooled"} {
			t.Run(preferred+"/"+factory, func(t *testing.T) {
				policytest.Set(t, nil)
				t.Setenv("HOME", t.TempDir())
				t.Setenv("CODEX_HOME", t.TempDir())
				reserve := "codex"
				if preferred == reserve {
					reserve = "claude"
				}
				cfg := &config.Config{ActiveWorkspace: "test"}
				cfg.AI.Provider = preferred
				cfg.AI.ConfiguredProvider = preferred
				cfg.AI.Fallback = config.AIFallbackConfig{Enabled: true, Provider: reserve}
				cfg.ClaudePath = routingCLI(t, "claude", preferred == "claude")
				cfg.CodexPath = routingCLI(t, "codex", preferred == "codex")
				sink := &ledgerSink{}
				llmusage.SetSink(sink)
				t.Cleanup(func() { llmusage.SetSink(nil) })
				var gen digest.Generator
				switch factory {
				case "cli":
					gen = cliGenerator(cfg)
				case "bounded":
					gen = cliBoundedGenerator(cfg)
				case "pooled":
					var cleanup func()
					gen, cleanup = cliPooledGenerator(cfg)
					t.Cleanup(cleanup)
				}
				ctx := digest.WithSource(context.Background(), "digest.channel_batch")
				text, _, _, err := gen.Generate(ctx, "", "request", "")
				if err != nil || text != "ok" {
					t.Fatal(text, err)
				}
				if len(sink.calls) != 2 {
					t.Fatalf("leaf rows: %+v", sink.calls)
				}
				for i, c := range sink.calls {
					provider := preferred
					if i == 1 {
						provider = reserve
					}
					light, _ := providers.ResolveModelsFor(cfg, provider)
					if c.Provider != provider || c.Model != light || c.OperationID == "" || c.Attempt != i+1 || c.ConfigRevision != providers.RoutingRevision(cfg) {
						t.Fatalf("leaf[%d]: %+v", i, c)
					}
				}
				if sink.calls[0].OperationID != sink.calls[1].OperationID {
					t.Fatal("attempts not linked")
				}
			})
		}
	}
}
func TestRoutingExplicitSameProviderOrModelPinAndAskGuardStayLegacy(t *testing.T) {
	for _, pin := range []string{"provider", "model", "ask_guard", "off"} {
		t.Run(pin, func(t *testing.T) {
			policytest.Set(t, nil)
			t.Setenv("HOME", t.TempDir())
			t.Setenv("CODEX_HOME", t.TempDir())
			oldProvider, oldModel := flagProvider, aiFlagModel
			t.Cleanup(func() { flagProvider, aiFlagModel = oldProvider, oldModel })
			flagProvider, aiFlagModel = "", ""
			cfg := &config.Config{}
			cfg.AI.Provider = "claude"
			cfg.AI.ConfiguredProvider = "claude"
			cfg.AI.Fallback = config.AIFallbackConfig{Enabled: true, Provider: "codex"}
			cfg.ClaudePath = routingCLI(t, "claude", true)
			cfg.CodexPath = routingCLI(t, "codex", false)
			switch pin {
			case "provider":
				flagProvider = "claude"
			case "model":
				aiFlagModel = "opus"
			case "off":
				cfg.AI.Fallback.Enabled = false
			}
			sink := &ledgerSink{}
			llmusage.SetSink(sink)
			t.Cleanup(func() { llmusage.SetSink(nil) })
			gen := cliGenerator(cfg)
			if pin == "ask_guard" {
				gen = askGuardGeneratorFactory(cfg)
			}
			_, _, _, err := gen.Generate(context.Background(), "", "request", "")
			var failure *providers.Failure
			if !errors.As(err, &failure) || failure.Category != providers.Quota || len(sink.calls) != 1 || sink.calls[0].OperationID != "" {
				t.Fatalf("legacy: %v %+v", err, sink.calls)
			}
		})
	}
}
func TestPolicyImageCapabilityAcrossPoolAndTimeout(t *testing.T) {
	policytest.Set(t, nil)
	leaf := &routingImageLeaf{}
	pool := sessions.NewSessionPool(1)
	t.Cleanup(pool.Close)
	gen := digest.NewPooledGenerator(digest.WithCallTimeout(policyCheckedGenerator{inner: leaf, provider: "codex"}, time.Second), pool)
	image, ok := digest.ImageCapable(gen)
	if !ok {
		t.Fatal("policy lost image capability")
	}
	if _, _, err := image.GenerateWithImage(context.Background(), "", "", "image", "image/png"); err != nil {
		t.Fatal(err)
	}
	claudeOnly(t)
	if _, _, err := image.GenerateWithImage(context.Background(), "", "", "image", "image/png"); !errors.Is(err, policy.ErrNotAllowed) {
		t.Fatal(err)
	}
	if leaf.calls != 1 {
		t.Fatal("policy bypassed", leaf.calls)
	}
	if _, ok := digest.ImageCapable(policyCheckedGenerator{inner: &countingGenerator{}, provider: "codex"}); ok {
		t.Fatal("invented image support")
	}
}

type routingImageLeaf struct{ calls int }

func (g *routingImageLeaf) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	return "", nil, "", nil
}
func (g *routingImageLeaf) GenerateWithImage(context.Context, string, string, string, string) (string, *digest.Usage, error) {
	g.calls++
	return "ok", nil, nil
}

func TestRoutingImageActualModelMatchesStrongAttemptWithLightPurpose(t *testing.T) {
	policytest.Set(t, nil)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CODEX_HOME", t.TempDir())
	cfg := &config.Config{}
	cfg.AI.Provider = "claude"
	cfg.AI.ConfiguredProvider = "claude"
	cfg.AI.Fallback = config.AIFallbackConfig{Enabled: true, Provider: "codex"}
	cfg.ClaudePath = routingCLI(t, "claude", false)
	cfg.CodexPath = routingCLI(t, "codex", false)
	sink := &ledgerSink{}
	llmusage.SetSink(sink)
	t.Cleanup(func() { llmusage.SetSink(nil) })
	gen := cliBoundedGenerator(cfg)
	image, ok := digest.ImageCapable(gen)
	if !ok {
		t.Fatal("image unsupported")
	}
	path := filepath.Join(t.TempDir(), "image.png")
	if err := os.WriteFile(path, []byte("fake-image"), 0600); err != nil {
		t.Fatal(err)
	}
	ctx := digest.WithWorkDir(digest.WithSource(context.Background(), "digest.channel_batch"), t.TempDir())
	if _, _, err := image.GenerateWithImage(ctx, "", "request", path, "image/png"); err != nil {
		t.Fatal(err)
	}
	if len(sink.calls) != 1 || sink.calls[0].Model != "opus" || sink.calls[0].Purpose != "digest.channel_batch" {
		t.Fatal(sink.calls)
	}
}
