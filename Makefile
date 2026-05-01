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

.PHONY: build test test-cover lint lint-swift lint-all install clean app app-dev dmg test-swift sentrux-check sentrux-gate sentrux-baseline quality periphery periphery-check periphery-baseline release-check

build:
	go build $(LDFLAGS) -o $(BINARY_NAME) .

app dmg:
	./scripts/build-app.sh $(VERSION)

app-dev:
	./scripts/build-app.sh --dev $(VERSION)

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
