# Fifth merge of origin/main into feature/mobile-e2e — 2026-10-13

Merged `origin/main` at `0c7e71a4` (#236 dismiss asks, 25 files). Merge commit `ae7b6323`. No textual conflicts; no fix commit needed. Nothing pushed. origin/main had not moved again at the end.

## E2E review of #236
- Phone->Mac: no new action. The phone only reads dismissals.
- Mac->phone: `OwnerAskAnswer.dismissed` is a field inside the ask's answer JSON, which already travels in the sealed ask slice (Kit `OwnerAsk.swift`, phone `AskFormModel` shows "Dismissed"). No new CKRecord field, no raw transport write.
- Go (`internal/asks`) and Desktop changes are Mac-local.

## Results
| Command | Result |
|---|---|
| `make kit-test` | exit 0, 702 tests, 0 failures |
| `swift build --build-tests` (Desktop) | exit 0 |
| `make test-swift FILTER='OwnerAsk\|AskAlertSliceTests\|RelayProcessor\|SlicePublisherTests\|MobileHubServiceTests'` | exit 0, 458 tests, 0 failures |
| `make mobile-build SIM='iPhone 17 Pro'` | BUILD SUCCEEDED |
| `make mobile-test SIM='iPhone 17 Pro'` | exit 0, 590 tests, 2 skipped, 0 failures |
| `make lint-diff` | 0 issues |
| `make lint-swift` | 0 violations |
| `go build ./...`, `go test ./internal/asks` | ok |
