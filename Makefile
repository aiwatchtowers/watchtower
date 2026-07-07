-include .env
export WATCHTOWER_OAUTH_CLIENT_ID WATCHTOWER_OAUTH_CLIENT_SECRET WATCHTOWER_GOOGLE_CLIENT_ID WATCHTOWER_GOOGLE_CLIENT_SECRET WATCHTOWER_JIRA_CLIENT_ID WATCHTOWER_JIRA_CLIENT_SECRET

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
LDFLAGS     := -ldflags "-X watchtower/cmd.Version=$(VERSION) -X watchtower/cmd.Commit=$(COMMIT) -X watchtower/cmd.BuildDate=$(BUILD_DATE) -X watchtower/internal/auth.DefaultClientID=$(OAUTH_ID) -X watchtower/internal/auth.DefaultClientSecret=$(OAUTH_SECRET) -X watchtower/internal/calendar.DefaultGoogleClientID=$(GOOGLE_ID) -X watchtower/internal/calendar.DefaultGoogleClientSecret=$(GOOGLE_SECRET) -X watchtower/internal/jira.DefaultJiraClientID=$(JIRA_ID) -X watchtower/internal/jira.DefaultJiraClientSecret=$(JIRA_SECRET)"

.PHONY: build test test-cover lint lint-swift lint-all install clean app app-dev dmg test-swift sentrux-check sentrux-gate sentrux-baseline quality periphery periphery-check periphery-baseline release-check mobile-gen mobile-build mobile-test mobile-run mobile-archive smoke-live

# Simulator device for the mobile targets; override: make mobile-run SIM="iPhone 17e"
SIM ?= iPhone 17 Pro
MOBILE_PROJ := WatchtowerMobile/WatchtowerMobile.xcodeproj
MOBILE_DEST := platform=iOS Simulator,name=$(SIM)

build:
	go build $(LDFLAGS) -o $(BINARY_NAME) .

app dmg:
	./scripts/build-app.sh $(VERSION)

app-dev:
	./scripts/build-app.sh --dev $(VERSION)

# Regenerate the Xcode project after editing WatchtowerMobile/project.yml
# (the yml is the source of truth; commit the regenerated .xcodeproj too).
mobile-gen:
	cd WatchtowerMobile && xcodegen generate

mobile-build:
	xcodebuild build -project $(MOBILE_PROJ) -scheme WatchtowerMobile \
		-destination '$(MOBILE_DEST)' CODE_SIGNING_ALLOWED=NO

mobile-test:
	xcodebuild test -project $(MOBILE_PROJ) -scheme WatchtowerMobile \
		-destination '$(MOBILE_DEST)' CODE_SIGNING_ALLOWED=NO

# Build + boot the simulator + install + launch — the mobile app-dev.
mobile-run: mobile-build
	xcrun simctl boot "$(SIM)" 2>/dev/null || true
	open -a Simulator
	xcrun simctl install "$(SIM)" "$$(xcodebuild -project $(MOBILE_PROJ) -scheme WatchtowerMobile -destination '$(MOBILE_DEST)' -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{d=$$3} / FULL_PRODUCT_NAME/{n=$$3} END{print d "/" n}')"
	xcrun simctl launch "$(SIM)" com.aiwatchtowers.watchtower.mobile

# TestFlight archive lane (Decision 9): Release archive for generic iOS +
# .ipa export via the committed app-store-connect ExportOptions.plist.
# Requires the gitignored WatchtowerMobile/Signing.xcconfig (real
# DEVELOPMENT_TEAM) — checked first so a missing file fails with instructions
# instead of a cryptic xcodebuild signing dump. The ASC upload itself is a
# USER GATE: open build/WatchtowerMobile.xcarchive in Xcode Organizer
# ("Distribute App"), or hand build/WatchtowerMobile-export/*.ipa to
# Transporter. ASC API-key automation is out of v1.
MOBILE_ARCHIVE := build/WatchtowerMobile.xcarchive
mobile-archive:
	@if [ ! -f WatchtowerMobile/Signing.xcconfig ]; then \
		echo "error: WatchtowerMobile/Signing.xcconfig not found — archiving needs a real signing identity."; \
		echo ""; \
		echo "  1. cp WatchtowerMobile/Signing.xcconfig.template WatchtowerMobile/Signing.xcconfig"; \
		echo "  2. Fill in DEVELOPMENT_TEAM (developer.apple.com > Membership)."; \
		echo "  3. One-time: open WatchtowerMobile/WatchtowerMobile.xcodeproj in Xcode with"; \
		echo "     automatic signing so it mints the iCloud container + provisioning profiles."; \
		echo ""; \
		echo "Signing.xcconfig is gitignored on purpose — never commit a team ID."; \
		exit 1; \
	fi
	xcodebuild archive -project $(MOBILE_PROJ) -scheme WatchtowerMobile \
		-configuration Release -destination 'generic/platform=iOS' \
		-archivePath $(MOBILE_ARCHIVE)
	xcodebuild -exportArchive -archivePath $(MOBILE_ARCHIVE) \
		-exportOptionsPlist WatchtowerMobile/ExportOptions.plist \
		-exportPath build/WatchtowerMobile-export
	@echo "✓ .ipa in build/WatchtowerMobile-export — upload via Xcode Organizer or Transporter (user gate)."

# Live-API smoke — the ONLY place the frozen BYOK wire format meets the real
# Anthropic server (WatchtowerKit/LiveAPISmokeTests). Needs ANTHROPIC_LIVE_KEY
# in the environment (passed through at runtime, never persisted — do NOT put
# it in .env); without the key the suite skips. Costs real money (~a few cents
# on claude-haiku-4-5). MUST be run green once before any user-facing ship:
#   ANTHROPIC_LIVE_KEY=sk-ant-... make smoke-live
smoke-live:
	cd WatchtowerKit && swift test --filter LiveAPISmokeTests

test:
	go test ./... -v

# Coverage gate — fails when any package in coverage.thresholds
# regresses below its declared floor. Run after touching production
# code to confirm tests still cover the moved/changed paths.
test-cover:
	./scripts/coverage-gate.sh

test-swift:
	cd WatchtowerDesktop && swift test

lint:
	golangci-lint run ./...

lint-swift:
	cd WatchtowerDesktop && swiftlint lint --strict --baseline .swiftlint-baseline.json

lint-all: lint lint-swift

install:
	go install $(LDFLAGS) .

clean:
	rm -f $(BINARY_NAME)
	rm -rf build/

# Architectural rules + structural regression via sentrux.
# `make quality` runs both: check (rules in .sentrux/rules.toml) and gate
# (regression vs .sentrux/baseline.json). `make sentrux-baseline` refreshes
# the baseline after intentional structural changes.
SENTRUX ?= $(shell command -v sentrux 2>/dev/null || echo /opt/homebrew/bin/sentrux)
sentrux-check:
	$(SENTRUX) check .

sentrux-gate:
	$(SENTRUX) gate .

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

# Pre-release gate. Runs sentrux quality (rules + structural regression),
# periphery dead-code check (vs baseline), Go tests, and Swift tests. Failing
# any of these halts the release. Used by .claude/commands/release.md before
# `make app`.
release-check: quality periphery-check test test-swift
	@echo "✓ release-check passed"
