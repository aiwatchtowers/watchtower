# ENV_FILE selects the build profile (default .env). Alternative profiles
# (e.g. ENV_FILE=.env.b2 make app) carry their own credentials and must set
# BUILD_FLAVOR, which is baked into the binary and artifact names.
# Mirror of the build-app.sh profile-selection guards: `-include` is silent on
# a missing file, which would bake empty credentials with exit 0 on the
# `make build`/`make install` paths that never reach the script.
# app-dev defaults to the dev profile; an explicit ENV_FILE=... on the
# command line or environment still wins (?= never overrides those).
ifneq ($(filter app-dev,$(MAKECMDGOALS)),)
ENV_FILE ?= .env.dev
endif
ENV_FILE ?= .env
-include $(ENV_FILE)
ifneq ($(ENV_FILE),.env)
ifeq ($(wildcard $(ENV_FILE)),)
$(error build profile '$(ENV_FILE)' not found)
endif
ifeq ($(strip $(BUILD_FLAVOR)),)
$(error build profile '$(ENV_FILE)' must set BUILD_FLAVOR)
endif
endif
export ENV_FILE
export WATCHTOWER_OAUTH_CLIENT_ID WATCHTOWER_OAUTH_CLIENT_SECRET WATCHTOWER_GOOGLE_CLIENT_ID WATCHTOWER_GOOGLE_CLIENT_SECRET WATCHTOWER_JIRA_CLIENT_ID WATCHTOWER_JIRA_CLIENT_SECRET BUILD_FLAVOR

BINARY_NAME := watchtower
VERSION     ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
COMMIT      ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE  ?= $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
OAUTH_ID    ?= $(WATCHTOWER_OAUTH_CLIENT_ID)
OAUTH_SECRET?= $(WATCHTOWER_OAUTH_CLIENT_SECRET)
GOOGLE_ID   ?= $(WATCHTOWER_GOOGLE_CLIENT_ID)
GOOGLE_SECRET?= $(WATCHTOWER_GOOGLE_CLIENT_SECRET)
JIRA_ID     ?= $(WATCHTOWER_JIRA_CLIENT_ID)
JIRA_SECRET ?= $(WATCHTOWER_JIRA_CLIENT_SECRET)
LDFLAGS     := -ldflags "-X watchtower/cmd.Version=$(VERSION) -X watchtower/cmd.Commit=$(COMMIT) -X watchtower/cmd.BuildDate=$(BUILD_DATE) -X watchtower/cmd.BuildFlavor=$(BUILD_FLAVOR) -X watchtower/internal/auth.DefaultClientID=$(OAUTH_ID) -X watchtower/internal/auth.DefaultClientSecret=$(OAUTH_SECRET) -X watchtower/internal/calendar.DefaultGoogleClientID=$(GOOGLE_ID) -X watchtower/internal/calendar.DefaultGoogleClientSecret=$(GOOGLE_SECRET) -X watchtower/internal/jira.DefaultJiraClientID=$(JIRA_ID) -X watchtower/internal/jira.DefaultJiraClientSecret=$(JIRA_SECRET)"

.PHONY: build test test-verbose test-cover test-codeindex-full lint lint-diff lint-swift lint-all install clean app app-dev dmg app-swap app-install test-swift test-swift-strict-pool kit-test test-scripts hooks leak-check sentrux-check sentrux-gate sentrux-baseline quality periphery periphery-check periphery-baseline release-check editor-bridge-check

build:
	go build $(LDFLAGS) -o $(BINARY_NAME) .

app dmg:
	./scripts/build-app.sh $(VERSION)

app-dev:
	./scripts/build-app.sh --dev $(VERSION)

# `make app` builds into build.next/ and swaps it into build/ at the end; while
# the app runs from build/ the swap is deferred until you quit it and run
# `make app-swap` (WAIT=1 waits for the quit). `make app-install` copies
# build/Watchtower.app to INSTALL_DIR so build/ stays free for the next build.
INSTALL_DIR ?= /Applications
app-swap:
	./scripts/app-swap.sh

app-install:
	INSTALL_DIR="$(INSTALL_DIR)" ./scripts/app-install.sh

test:
	go test ./...

test-verbose:
	go test ./... -v

# The code index over the full grammar set (-tags codegrammars, the release
# build's). Plain `make test` and the inner loop stay untagged: they compile
# only the Go, Swift and Python grammars the index's own tests need.
test-codeindex-full:
	go test -tags codegrammars ./internal/codeindex/...

# Coverage gate — fails when any package in coverage.thresholds
# regresses below its declared floor. Run after touching production
# code to confirm tests still cover the moved/changed paths.
test-cover:
	./scripts/coverage-gate.sh

# Inner-loop Swift tests: make test-swift FILTER=SomeTestClass runs only that
# class (a regex alternation works too: FILTER='ClassA|ClassB' — the recipe
# single-quotes it so the | never reaches the shell); without FILTER the full
# suite runs as before, followed by the mobile Kit suite (kit-test), so the
# gate covers both packages.
test-swift:
	cd WatchtowerDesktop && swift test $(if $(FILTER),--filter '$(FILTER)',)
	$(if $(FILTER),,$(MAKE) kit-test)

# Inner-loop tests for the shared mobile Kit package (WatchtowerSync +
# WatchtowerKit): make kit-test FILTER=SomeTestClass (a regex alternation
# works too). Without FILTER the whole Kit suite runs — it is small and links
# no ML stack.
kit-test:
	cd WatchtowerKit && swift test $(if $(FILTER),--filter '$(FILTER)',)

# The suites that spawn child processes, on a one-thread Swift concurrency
# pool: a blocking pipe read or waitUntilExit on a pool thread (instead of
# ProcessPipes' own threads) hangs or times out here, as it did on the 3-core
# CI runner. Runs after a test build (--skip-build); CI runs it in Swift Test.
# A new suite that spawns a child process belongs in this list.
STRICT_POOL_SUITES = ProcessPipes|CLIRunner|JiraBoardsCLITests|DaemonManager|UpdateService|FoundationChatSessionProcessTests|CodeCLIProcessTests|CodeIndexCenterTests|CodeNavRealCLITests|OpenQuicklyCenterTests|CodeUsagesCenterTests|CodeNavQuitTests
test-swift-strict-pool:
	cd WatchtowerDesktop && LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --skip-build --filter '$(STRICT_POOL_SUITES)'

# Shell-level tests for build-app.sh and the app-swap/app-install scripts. They
# extract marked blocks or run the scripts in a temp tree against stubbed
# binaries — no real build, no codesign.
test-scripts:
	@rc=0; for t in scripts/tests/test-*.sh; do \
	  echo "==> $$t"; \
	  bash "$$t" || rc=1; \
	done; exit $$rc

# Installs the repo's git hooks (scripts/git-hooks: pre-push runs leak-check)
# for every worktree of this clone. Run once per clone.
hooks:
	git config core.hooksPath scripts/git-hooks

# Scans this branch's commits for live-install data (see scripts/leak-check.sh).
leak-check:
	bash scripts/leak-check.sh origin/main..HEAD

lint:
	golangci-lint run ./...

# Inner-loop lint: only issues introduced relative to origin/main.
# The full `lint` target remains the pre-PR gate.
lint-diff:
	golangci-lint run --new-from-rev origin/main ./...

lint-swift:
	cd WatchtowerDesktop && swiftlint lint --strict --baseline .swiftlint-baseline.json
	cd WatchtowerKit && swiftlint lint --strict

lint-all: lint lint-swift

install:
	go install $(LDFLAGS) .

clean:
	rm -f $(BINARY_NAME)
	rm -rf build/ build.next/ build.old/

# Architectural rules + structural regression via sentrux.
# `make quality` runs both: check (rules in .sentrux/rules.toml) and gate
# (regression vs .sentrux/baseline.json, via scripts/sentrux-gate.sh — see
# that script's header for why it doesn't block on the raw god-file count).
# `make sentrux-baseline` refreshes the baseline after intentional structural
# changes.
SENTRUX ?= $(shell command -v sentrux 2>/dev/null || echo /opt/homebrew/bin/sentrux)
sentrux-check:
	$(SENTRUX) check .

sentrux-gate:
	scripts/sentrux-gate.sh

sentrux-baseline:
	$(SENTRUX) gate --save .

quality: sentrux-check sentrux-gate

# Dead Swift code detection. Periphery scans the WatchtowerDesktop SPM target
# and reports unused declarations. The check target gates new dead code:
# the current count is frozen in WatchtowerDesktop/.periphery-baseline-count.txt
# and any increase fails the gate. Refresh after intentional cleanup with
# `make periphery-baseline`.
PERIPHERY ?= $(shell command -v periphery 2>/dev/null || echo /usr/local/bin/periphery)
periphery:
	cd WatchtowerDesktop && swift build && $(PERIPHERY) scan --skip-build

periphery-check:
	@cd WatchtowerDesktop && swift build >/dev/null 2>&1 && \
	current=$$($(PERIPHERY) scan --skip-build 2>/dev/null | grep -cE "warning:" || echo 0); \
	baseline=$$(cat .periphery-baseline-count.txt 2>/dev/null || echo 0); \
	if [ "$$current" -gt "$$baseline" ]; then \
	  echo "✗ Periphery: dead-code count $$current > baseline $$baseline (+$$(($$current - $$baseline))). Clean it up or refresh with 'make periphery-baseline'."; \
	  exit 1; \
	else \
	  echo "✓ Periphery: $$current ≤ baseline $$baseline"; \
	fi

periphery-baseline:
	@cd WatchtowerDesktop && swift build >/dev/null 2>&1 && \
	count=$$($(PERIPHERY) scan --skip-build 2>/dev/null | grep -cE "warning:" || echo 0); \
	echo "$$count" > .periphery-baseline-count.txt; \
	echo "Periphery baseline saved: $$count warnings"

# Manual check of the Files pane's editor page (CodeEditorWeb/index.html
# protocol + languages.js grammars) in a headless WKWebView. Not in any gate;
# needs scripts/fetch-monaco.sh first.
editor-bridge-check:
	bash scripts/editor-bridge-check.sh

# Pre-release gate. Runs sentrux quality (rules + structural regression),
# periphery dead-code check (vs baseline), Go tests, and Swift tests. Failing
# any of these halts the release. Used by .claude/commands/release.md before
# `make app`.
release-check: quality periphery-check test test-swift test-scripts
	@echo "✓ release-check passed"
