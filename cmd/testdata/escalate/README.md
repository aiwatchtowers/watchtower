# `workbench escalate-question` envelopes

One file per envelope the verb prints, plus `contract.json` (the reasons it takes, its error codes, and the transient codes the Desktop retries). `TestEscalateEnvelopeGoldens` and `TestEscalateContractGolden` in `cmd/workbench_escalate_golden_test.go` write them from the real constants (`go test ./cmd/ -run 'TestEscalate.*Golden' -update`) and fail when the code drifts; the Swift side decodes the same files, so a change here is a change to the Desktop contract.
