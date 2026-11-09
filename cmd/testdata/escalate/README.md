# `workbench escalate-question` envelopes

One file per envelope the verb prints, plus `contract.json` (the reasons it takes, its error codes, and the transient codes the Desktop retries). `TestEscalateEnvelopeGoldens` and `TestEscalateContractGolden` in `cmd/workbench_escalate_golden_test.go` write them from the real constants (`go test ./cmd/ -run 'TestEscalate.*Golden' -update`) and fail when the code drifts; the Swift side decodes the same files, so a change here is a change to the Desktop contract.

`summaries.json` is the raised ask's summary in each shape (`TestEscalateSummaryGolden`: the reason lines for left, away and timeout at 0 and 12 min; context + blank line + reason, the reason alone, a full request's whole text + newline + reason), with the Go title and what the Desktop drawer shows of it (`body` in the bubble, `reason_line` as the caption). `OwnerAskSummaryPartsTests` feeds every case through `OwnerAskPresentation.summaryParts`.
