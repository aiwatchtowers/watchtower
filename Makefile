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
export WATCHTOWER_OAUTH_CLIENT_ID WATCHTOWER_OAUTH_CLIENT_SECRET WATCHTOWER_GOOGLE_CLIENT_ID WATCHTOWER_GOOGLE_CLIENT_SECRET WATCHTOWER_JIRA_CLIENT_ID WATCHTOWER_JIRA_CLIENT_SECRET WATCHTOWER_PURGE_DEFAULT WATCHTOWER_LINK_FETCH_DENY_HOSTS BUILD_FLAVOR

BINARY_NAME := watchtower
VERSION     ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
COMMIT      ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE  ?= $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
OAUTH_ID    ?= $(WATCHTOWER_OAUTH_CLIENT_ID)
OAUTH_SECRET?= $(WATCHTOWER_OAUTH_CLIENT_SECRET)
GOOGLE_ID   ?= $(WATCHTOWER_GOOGLE_CLIENT_ID)
GOOGLE_SECRET?= $(WATCHTOWER_GOOGLE_CLIENT_SECRET)
JIRA_ID     ?= $(WATCHTOWER_JIRA_CLIENT_ID)
LINEAR_ID   ?= $(WATCHTOWER_LINEAR_CLIENT_ID)
JIRA_SECRET ?= $(WATCHTOWER_JIRA_CLIENT_SECRET)
PURGE_DEFAULT ?= $(WATCHTOWER_PURGE_DEFAULT)
# Comma-separated, no spaces: hosts the media pass never fetches (corp build).
LINK_FETCH_DENY_HOSTS ?= $(WATCHTOWER_LINK_FETCH_DENY_HOSTS)
LDFLAGS     := -ldflags "-X watchtower/cmd.Version=$(VERSION) -X watchtower/cmd.Commit=$(COMMIT) -X watchtower/cmd.BuildDate=$(BUILD_DATE) -X watchtower/cmd.BuildFlavor=$(BUILD_FLAVOR) -X watchtower/internal/auth.DefaultClientID=$(OAUTH_ID) -X watchtower/internal/auth.DefaultClientSecret=$(OAUTH_SECRET) -X watchtower/internal/calendar.DefaultGoogleClientID=$(GOOGLE_ID) -X watchtower/internal/calendar.DefaultGoogleClientSecret=$(GOOGLE_SECRET) -X watchtower/internal/jira.DefaultJiraClientID=$(JIRA_ID) -X watchtower/internal/jira.DefaultJiraClientSecret=$(JIRA_SECRET) -X watchtower/internal/linear.DefaultLinearClientID=$(LINEAR_ID) -X watchtower/internal/purge.BuildDefault=$(PURGE_DEFAULT) -X watchtower/internal/media.BuildDenyHosts=$(LINK_FETCH_DENY_HOSTS) -X watchtower/internal/hub/identity.KeychainBuildFlag=false"

.PHONY: golangci-version-check build test test-verbose test-cover test-race race-packages test-codeindex-full lint lint-diff lint-swift lint-all install clean app app-dev dmg app-swap app-install test-swift test-swift-strict-pool kit-test e2e-vectors test-scripts hooks leak-check periphery periphery-check periphery-baseline release-check editor-bridge-check mobile-gen mobile-build mobile-test mobile-run mobile-shots desktop-shots design-gallery mobile-archive mobile-testflight testflight cloudkit-check relay-go relay-interop hub-smoke

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

# The race pass (CI on main pushes and workflow_dispatch, the release gate):
# every package but cmd (CLI glue over file-backed SQLite fixtures; its
# concurrency lives in internal/*). internal/db runs apart, without its
# migration and schema-snapshot tests: they replay goose migrations — one
# goroutine of SQL — and were 2 910 of the package's 3 170 s under -race
# (local, 2026-10-14), past the 25 m per-package timeout on a CI runner.
# They run without -race in test-cover. The skip matches top-level names, so
# an internal/db test of concurrency keeps those words out of its name.
# internal/db runs alongside the rest (as one invocation did before) and both
# results count; its log follows the rest's.
#
# SHARD=K/N runs only the K-th of N disjoint slices (CI's go-test-race matrix:
# 1/3, 2/3 and 3/3); without SHARD every package runs, as before. `make
# race-packages [SHARD=K/N]` prints a slice's list. The split is deterministic:
# the RACE_HEAVY packages first, in their listed order, then the rest in
# `go list` (sorted) order, dealt round-robin — package i goes to shard
# i mod N + 1. RACE_HEAVY is ordered so that dealing it in threes evens out
# the race-pass seconds per shard (CI, 2026-10-19: automations 880, kb 821,
# db ~600 with the compaction tests, tools ~580, sessionreport 562, digest
# 374, memory 360, daemon 296, agentlogdb 209, extsync 202, jira 190, repl
# 187 — ~1.75k heavy CPU-s per shard; two shards put ~4.3k on one runner and
# timed out at 25 m).
# To rebalance, read the per-package seconds off a race run's log and reorder
# (or extend) the list so each shard's heavy sum stays level; a package new
# to the module needs nothing — it lands in a shard by itself.
RACE_SKIP := Migration|DownUp|SchemaGolden|DesktopTestSchema
RACE_HEAVY := automations kb db digest sessionreport tools daemon agentlogdb memory extsync repl jira
RACE_PACKAGES = go list ./... | grep -v -e '^watchtower/cmd$$' | awk -v shard='$(SHARD)' -v heavy='$(RACE_HEAVY)' ' \
	{ pkgs[NR] = $$0; have[$$0] = 1 } \
	END { \
		if (shard == "") { for (i = 1; i <= NR; i++) print pkgs[i]; exit } \
		if (split(shard, kn, "/") != 2 || kn[1] !~ /^[0-9]+$$/ || kn[2] !~ /^[0-9]+$$/ || kn[1] < 1 || kn[1] > kn[2]) { \
			print "SHARD must be K/N with 1 <= K <= N, got " shard > "/dev/stderr"; exit 1 } \
		n = 0; nh = split(heavy, hs, " "); \
		for (j = 1; j <= nh; j++) { p = "watchtower/internal/" hs[j]; if (p in have && !(p in seen)) { seen[p] = 1; order[n++] = p } } \
		for (i = 1; i <= NR; i++) if (!(pkgs[i] in seen)) order[n++] = pkgs[i]; \
		for (i = 0; i < n; i++) if (i % kn[2] == kn[1] - 1) print order[i] \
	}'

race-packages:
	@$(RACE_PACKAGES)

test-race:
	@pkgs="$$($(RACE_PACKAGES))" || exit 1; \
	[ -n "$$pkgs" ] || { echo "test-race: no packages to test (did go list fail?)" >&2; exit 1; }; \
	db=0; rest=""; for p in $$pkgs; do if [ "$$p" = watchtower/internal/db ]; then db=1; else rest="$$rest $$p"; fi; done; \
	db_log="$$(mktemp)"; \
	if [ $$db -eq 1 ]; then go test ./internal/db -race -count=1 -timeout 25m -skip '$(RACE_SKIP)' > "$$db_log" 2>&1 & db_pid=$$!; fi; \
	rc=0; if [ -n "$$rest" ]; then go test $$rest -race -count=1 -timeout 25m || rc=$$?; fi; \
	db_rc=0; if [ $$db -eq 1 ]; then wait $$db_pid || db_rc=$$?; fi; \
	cat "$$db_log"; rm -f "$$db_log"; \
	[ $$rc -eq 0 ] && [ $$db_rc -eq 0 ]

# Inner-loop Swift tests: make test-swift FILTER=SomeTestClass runs only that
# class (a regex alternation works too: FILTER='ClassA|ClassB' — the recipe
# single-quotes it so the | never reaches the shell); without FILTER the full
# suite runs as before, followed by the mobile Kit suite (kit-test), so the
# gate covers both packages.
test-swift:
	cd WatchtowerDesktop && caffeinate -i swift test $(if $(FILTER),--filter '$(FILTER)',)
	$(if $(FILTER),,caffeinate -i $(MAKE) kit-test)

# Inner-loop tests for the shared mobile Kit package (WatchtowerSync +
# WatchtowerKit): make kit-test FILTER=SomeTestClass (a regex alternation
# works too). Without FILTER the whole Kit suite runs — it is small and links
# no ML stack.
kit-test:
	cd WatchtowerKit && swift test $(if $(FILTER),--filter '$(FILTER)',)

# The Kit E2E vectors the Go hub's golden tests read: padding, envelope, kdf,
# hpke-envelope and asset .json in WatchtowerKit/Tests/Fixtures/e2e
# (hpke-rfc9180-a21.json is hand-transcribed from the RFC, never regenerated).
# The first run regenerates them (each vector test fails with "regenerated" on
# purpose, so its exit code is ignored); the second run verifies the new files.
# The leading "\." and trailing "/" anchor whole class names (no Replica*EnvelopeTests).
E2E_VECTOR_TESTS := \.(E2EPaddingVectorTests|HPKEEnvelopeVectorTests|EnvelopeTests|E2EKeyDerivationTests|ChunkedAssetCipherTests)/
e2e-vectors:  ## regenerate the Kit E2E vectors (expected XCTFail "regenerated"), then verify
	-WT_E2E_REGENERATE=1 $(MAKE) kit-test FILTER='$(E2E_VECTOR_TESTS)'
	$(MAKE) kit-test FILTER='$(E2E_VECTOR_TESTS)'

# iPhone app (WatchtowerMobile, an xcodegen project). Simulator device for
# the mobile targets; override: make mobile-run SIM="iPhone 17e".
SIM ?= iPhone 18 Pro
MOBILE_PROJ := WatchtowerMobile/WatchtowerMobile.xcodeproj
MOBILE_DEST := platform=iOS Simulator,name=$(SIM)
MOBILE_BUNDLE_ID := com.aiwatchtowers.watchtower.mobile
# make mobile-test MOBILE_FILTER=SomeTestClass runs only that class; an
# alternation (MOBILE_FILTER='ClassA|ClassB') becomes one -only-testing per class.
MOBILE_ONLY := $(foreach t,$(subst |, ,$(MOBILE_FILTER)),-only-testing:WatchtowerMobileTests/$(t))

# Regenerates WatchtowerMobile.xcodeproj from project.yml (never hand-edit it).
mobile-gen:
	cd WatchtowerMobile && xcodegen generate

mobile-build:
	xcodebuild build -project $(MOBILE_PROJ) -scheme WatchtowerMobile \
		-destination '$(MOBILE_DEST)' CODE_SIGNING_ALLOWED=NO

# The test host shares one on-disk replica with the simulator's installed app
# (spec §10), so the recipe boots the simulator and uninstalls the app first:
# a stale replica would fail ReplicaWiringTests' exact counts.
mobile-test:
	xcrun simctl boot "$(SIM)" 2>/dev/null || true
	xcrun simctl uninstall "$(SIM)" $(MOBILE_BUNDLE_ID) 2>/dev/null || true
	xcodebuild test -project $(MOBILE_PROJ) -scheme WatchtowerMobile \
		-destination '$(MOBILE_DEST)' CODE_SIGNING_ALLOWED=NO $(MOBILE_ONLY)

# Build, boot the simulator, install and launch: the mobile app-dev.
mobile-run: mobile-build
	xcrun simctl boot "$(SIM)" 2>/dev/null || true
	open -a Simulator
	xcrun simctl install "$(SIM)" "$$(xcodebuild -project $(MOBILE_PROJ) -scheme WatchtowerMobile -destination '$(MOBILE_DEST)' -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{d=$$3} / FULL_PRODUCT_NAME/{n=$$3} END{print d "/" n}')"
	xcrun simctl launch "$(SIM)" $(MOBILE_BUNDLE_ID)

# The design pass's screenshot tour (WatchtowerMobile/Tests/ScreenshotTourTests.swift):
# every demo screen in light and dark mode as PNGs plus an INDEX.md, written
# to SHOTS_DIR (under the gitignored build/). Compare a before and an after
# set by eye; nothing asserts pixels. xcodebuild hands TEST_RUNNER_-prefixed
# variables to the test process with the prefix stripped.
SHOTS_DIR ?= build/mobile-shots
mobile-shots:
	xcrun simctl boot "$(SIM)" 2>/dev/null || true
	xcrun simctl uninstall "$(SIM)" $(MOBILE_BUNDLE_ID) 2>/dev/null || true
	mkdir -p "$(SHOTS_DIR)"
	TEST_RUNNER_WATCHTOWER_SHOTS_DIR="$(abspath $(SHOTS_DIR))" xcodebuild test -project $(MOBILE_PROJ) \
		-scheme WatchtowerMobile -destination '$(MOBILE_DEST)' CODE_SIGNING_ALLOWED=NO \
		-only-testing:WatchtowerMobileTests/ScreenshotTourTests

# The Desktop style guide's shots (WatchtowerDesktop/Tests/DesignShots, #719):
# every DesignShotCatalog entry in light and dark mode as PNGs, written to
# DESKTOP_SHOTS (under the gitignored build/). Compare a before and an after
# set by eye; nothing asserts pixels. Its own variable, so mobile-shots keeps
# SHOTS_DIR's default.
DESKTOP_SHOTS ?= build/desktop-shots
desktop-shots:
	mkdir -p "$(DESKTOP_SHOTS)"
	cd WatchtowerDesktop && DESKTOP_SHOTS_DIR="$(abspath $(DESKTOP_SHOTS))" caffeinate -i swift test --filter DesignShotsTests

# The design gallery (#760): a separate window over the Desktop design kit,
# one page per token, component and pattern. Never part of the app bundle.
design-gallery:
	cd WatchtowerDesktop && swift run DesignGallery

# TestFlight archive: a Release archive for generic iOS plus an .ipa export
# through the committed ExportOptions.plist. Needs the gitignored
# WatchtowerMobile/Signing.xcconfig (a real DEVELOPMENT_TEAM). The build
# number is the Unix time of the archive, so every upload is unique and newer
# than the last one (App Store Connect refuses a reused or lower number); the
# command line overrides it for the app and both extensions alike. Pin it with
# make mobile-archive MOBILE_BUILD_NUMBER=N. The version (MARKETING_VERSION)
# is the Mac's VERSION without the v, cut to x.y.z because iOS takes at most
# three numbers: git describe's v0.15.0-12-g<sha>-dirty gives 0.15.0, and a
# release's make testflight VERSION=0.16.0 gives 0.16.0, the same number its
# make app VERSION=0.16.0 stamps on the Mac. Override with MOBILE_VERSION=x.y.z.
MOBILE_ARCHIVE := build/WatchtowerMobile.xcarchive
MOBILE_EXPORT := build/WatchtowerMobile-export
ifndef MOBILE_BUILD_NUMBER
MOBILE_BUILD_NUMBER := $(shell date -u +%s)
endif
ifndef MOBILE_VERSION
MOBILE_VERSION := $(shell echo '$(VERSION)' | sed -E 's/^v//; s/^([0-9]+(\.[0-9]+){0,2}).*/\1/')
endif
mobile-archive:
	@if [ ! -f WatchtowerMobile/Signing.xcconfig ]; then \
		echo "error: WatchtowerMobile/Signing.xcconfig not found; archiving needs a real signing identity."; \
		echo ""; \
		echo "  1. cp WatchtowerMobile/Signing.xcconfig.template WatchtowerMobile/Signing.xcconfig"; \
		echo "  2. Fill in DEVELOPMENT_TEAM (developer.apple.com > Membership)."; \
		echo "  3. One-time: open WatchtowerMobile/WatchtowerMobile.xcodeproj in Xcode with"; \
		echo "     automatic signing so it registers the iCloud container, the app group"; \
		echo "     and the provisioning profiles."; \
		echo ""; \
		echo "Signing.xcconfig is gitignored on purpose: never commit a team ID."; \
		exit 1; \
	fi
	@if ! echo "$(MOBILE_VERSION)" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$$'; then \
		echo "error: version '$(MOBILE_VERSION)' is not x.y.z (VERSION=$(VERSION)); pass VERSION=x.y.z or MOBILE_VERSION=x.y.z"; \
		exit 1; \
	fi
	xcodebuild archive -project $(MOBILE_PROJ) -scheme WatchtowerMobile \
		-configuration Release -destination 'generic/platform=iOS' \
		-archivePath $(MOBILE_ARCHIVE) $(MOBILE_ARCHIVE_AUTH) \
		CURRENT_PROJECT_VERSION=$(MOBILE_BUILD_NUMBER) MARKETING_VERSION=$(MOBILE_VERSION)
	xcodebuild -exportArchive -archivePath $(MOBILE_ARCHIVE) \
		-exportOptionsPlist WatchtowerMobile/ExportOptions.plist \
		-exportPath $(MOBILE_EXPORT) $(MOBILE_ARCHIVE_AUTH)
	@echo "Archived $(MOBILE_VERSION) ($(MOBILE_BUILD_NUMBER)): $(MOBILE_EXPORT)"

# Archive and upload to App Store Connect; the build then shows up in
# TestFlight once Apple has processed it. Authenticates with an App Store
# Connect API key that lives outside the repo (the repo is public):
#   ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
#   ~/.appstoreconnect/watchtower.mk with ASC_KEY_ID := ... and ASC_ISSUER_ID := ...
# (or the two as environment variables). It first runs cloudkit-check
# (SKIP_CLOUDKIT_CHECK=1 skips it). The upload re-exports the archive
# with destination=upload; the key (Admin role) also lets xcodebuild mint the
# certificates and profiles the archive and the App Store export need.
# Fails when CloudKit Production lacks record types or fields Development has
# (deployed only by hand in the CloudKit Console; cktool cannot). Needs a
# management token saved once: xcrun cktool save-token --type management.
cloudkit-check:
	bash scripts/cloudkit-schema-check.sh

-include $(HOME)/.appstoreconnect/watchtower.mk
ASC_KEY_ID ?=
ASC_ISSUER_ID ?=
ASC_KEY_PATH ?= $(HOME)/.appstoreconnect/private_keys/AuthKey_$(ASC_KEY_ID).p8
ASC_AUTH = -allowProvisioningUpdates -authenticationKeyPath "$(ASC_KEY_PATH)" \
	-authenticationKeyID "$(ASC_KEY_ID)" -authenticationKeyIssuerID "$(ASC_ISSUER_ID)"
testflight: mobile-testflight
mobile-testflight:
	@if [ -z "$(ASC_KEY_ID)" ] || [ -z "$(ASC_ISSUER_ID)" ]; then \
		echo "error: ASC_KEY_ID and ASC_ISSUER_ID are not set."; \
		echo "  Put them in ~/.appstoreconnect/watchtower.mk:"; \
		echo "    ASC_KEY_ID := <key id>"; \
		echo "    ASC_ISSUER_ID := <issuer id>"; \
		echo "  (App Store Connect > Users and Access > Integrations > App Store Connect API)"; \
		exit 1; \
	fi
	@if [ ! -f "$(ASC_KEY_PATH)" ]; then \
		echo "error: API key not found at $(ASC_KEY_PATH)"; \
		exit 1; \
	fi
	@if [ -z "$(SKIP_CLOUDKIT_CHECK)" ]; then bash scripts/cloudkit-schema-check.sh; fi
	$(MAKE) mobile-archive MOBILE_BUILD_NUMBER=$(MOBILE_BUILD_NUMBER) MOBILE_VERSION=$(MOBILE_VERSION) MOBILE_ARCHIVE_AUTH='$(ASC_AUTH)'
	cp WatchtowerMobile/ExportOptions.plist build/ExportOptions-upload.plist
	plutil -replace destination -string upload build/ExportOptions-upload.plist
	xcodebuild -exportArchive -archivePath $(MOBILE_ARCHIVE) \
		-exportOptionsPlist build/ExportOptions-upload.plist \
		-exportPath $(MOBILE_EXPORT)-upload $(ASC_AUTH)
	@echo "Uploaded $(MOBILE_VERSION) ($(MOBILE_BUILD_NUMBER)); it appears in TestFlight after processing."
	@echo "The .ipa is in build/WatchtowerMobile-export: upload it with Xcode Organizer or Transporter."

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

# Copies the hosted relay's Go client + proto into internal/hub/transport/relay,
# pinned to REF (default: the commit in that dir's VERSION). Refuses a dirty or
# unpinned RELAY checkout. Public CI never runs it (Go hub design §6.1).
RELAY ?= ../relay
REF ?=
relay-go:
	bash scripts/relay-go.sh "$(RELAY)" $(REF)

# Runs the Go hub's interop tests (internal/hub/interop_test.go, build tag
# interop) against the relay's local stand: `wrangler dev` from
# $(RELAY)/worker in its own process group (needs Node and `npm ci` there),
# killed and waited for on exit, failure and signal. Any relay dir works; it
# warns when a git checkout is not at the vendored client's pin.
relay-interop:
	bash scripts/relay-interop.sh "$(RELAY)"

# The headless hub smoke test (cmd/hub_headless_smoke_test.go, build tag
# smoke): builds the binary, runs `sync --daemon` against an in-process fake
# relay and session host, pairs a Go phone from the terminal-free `hub pair`
# stream, starts a stub claude session and types one line into it. Live mode
# on Linux, the test workspace mode on darwin. CI runs it on amd64 and arm64.
hub-smoke:
	go test -tags smoke ./cmd -run TestHeadlessSmoke -timeout 5m

# Installs the repo's git hooks (scripts/git-hooks: pre-push runs leak-check)
# for every worktree of this clone. Run once per clone.
hooks:
	git config core.hooksPath scripts/git-hooks

# Scans this branch's commits for live-install data (see scripts/leak-check.sh).
leak-check:
	bash scripts/leak-check.sh origin/main..HEAD

# CI pins golangci-lint (.github/workflows/ci.yml); keep this in step with it.
# Another local version can disagree with CI both ways — gosec rules and
# nolintlint's unused-directive check differ between releases — so lint warns.
GOLANGCI_VERSION := 2.11.4
golangci-version-check:
	@golangci-lint version 2>/dev/null | grep -q 'version $(GOLANGCI_VERSION) ' || \
		echo "warning: golangci-lint is not v$(GOLANGCI_VERSION) (the CI version); results may differ from CI" >&2

lint: golangci-version-check
	golangci-lint run ./...

# Inner-loop lint: only issues introduced relative to origin/main.
# The full `lint` target remains the pre-PR gate.
lint-diff: golangci-version-check
	golangci-lint run --new-from-rev origin/main ./...

lint-swift:
	bash scripts/kit-lint-guard.sh
	cd WatchtowerDesktop && swiftlint lint --strict --baseline .swiftlint-baseline.json
	cd WatchtowerKit && swiftlint lint --strict
	cd WatchtowerMobile && swiftlint lint --strict

lint-all: lint lint-swift

install:
	go install $(LDFLAGS) .

clean:
	rm -f $(BINARY_NAME)
	rm -rf build/ build.next/ build.old/

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
# protocol + languages.js grammars + textmate.js highlighting) in a headless
# WKWebView. Not in any gate; needs scripts/fetch-monaco.sh first.
editor-bridge-check:
	bash scripts/editor-bridge-check.sh

# Pre-release gate. Runs the periphery dead-code check (vs baseline), Go
# tests, and Swift tests. Failing any of these halts the release. Used by
# .claude/commands/release.md before `make app`.
release-check: periphery-check test test-swift test-scripts
	@echo "✓ release-check passed"
