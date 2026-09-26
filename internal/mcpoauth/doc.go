// Package mcpoauth implements the OAuth discovery and (in later slices)
// authorization-code flow that lets Quick Connections sign in to an
// owner-added remote MCP server, per the MCP authorization spec:
// RFC 9728 (protected-resource metadata) feeding RFC 8414
// (authorization-server metadata), with an OpenID Connect discovery
// fallback for servers that only publish that document.
package mcpoauth
