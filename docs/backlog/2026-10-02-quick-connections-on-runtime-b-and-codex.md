---
type: idea
title: "Quick Connections for the ollama (runtime B) and codex providers"
status: open
priority: low
tags: [quick-connections, runtime-b, agentloop, codex, providers]
context: split out of the 2026-09-26 architecture low-priority bundle
created: 2026-10-02
---

External connections reach only the claude provider
(`*ai.Client.SetExternalMCPServers`, wired in `cmd/generator.go`'s
`newQueryClient`); codex and the ollama path ignore them, and the CLI/Desktop
only warn about it. The blocker the feature doc used to cite — no Go-owned
tool loop — is gone: runtime B (`internal/agentloop`) ships and drives the
ollama provider on chat surfaces through the `internal/tools` registry.

Direction: proxy each enabled external MCP server into the agentloop registry
as `External` tools, so an external write on ollama goes through
`Registry.Propose` and gets an approval card like any native write; for codex,
merge the servers into codex's own MCP config. Keep QC-02 (external tools are
read-only unless they pass through the propose/approve path) as the
acceptance bar. Related: the closed
`2026-09-26-quick-connections-external-write-tools-run-without-approve.md`.
