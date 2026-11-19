package planusage

// Reason codes of the plan-usage sources (claude.UsageError and
// codex.UsageError) and of the operations around them. Every set the
// package switches on is defined here.
const (
	CodeCLIMissing      = "cli_missing"
	CodeUnsupportedCLI  = "unsupported_cli"
	CodeNoCredentials   = "no_credentials"
	CodeUnsupportedAuth = "unsupported_auth"
	CodeCloudBedrock    = "cloud_bedrock"
	CodeCloudVertex     = "cloud_vertex"
	CodeCloudFoundry    = "cloud_foundry"
	CodeNetwork         = "network"
	CodeParse           = "parse"
	CodeTimeout         = "timeout"
	CodeCancelled       = "cancelled"
	CodeStorage         = "storage"
	CodeBusy            = "busy"
	CodeFeatureDisabled = "feature_disabled"
)

func codeSet(codes ...string) map[string]bool {
	set := make(map[string]bool, len(codes))
	for _, c := range codes {
		set[c] = true
	}
	return set
}

var (
	// cliCodes say nothing about the account: the row keeps its data.
	cliCodes = codeSet(CodeCLIMissing, CodeUnsupportedCLI)
	// accountCodes mean no plan limits apply to the account: the row's
	// plan label and numbers are cleared.
	accountCodes = codeSet(CodeNoCredentials, CodeUnsupportedAuth, CodeCloudBedrock, CodeCloudVertex, CodeCloudFoundry)
	// quietCodes are steady states that persist until the user changes
	// something; Provider.Run logs each once per change.
	quietCodes = codeSet(CodeCLIMissing, CodeUnsupportedCLI, CodeNoCredentials, CodeUnsupportedAuth,
		CodeCloudBedrock, CodeCloudVertex, CodeCloudFoundry)
	// storedReasons are the reasons a status row may carry and a reader
	// shows as themselves (safeStoredReason).
	storedReasons = codeSet(CodeNoCredentials, CodeUnsupportedAuth, CodeCloudBedrock, CodeCloudVertex, CodeCloudFoundry,
		CodeCLIMissing, CodeUnsupportedCLI, CodeNetwork, CodeParse, CodeTimeout)
	// publicCodes are the `usage plans --json` error codes; the Desktop's
	// PlansOperationError.codes must list exactly these
	// (TestPlanUsageCodes_SwiftPublicSetMatches).
	publicCodes = codeSet(CodeNoCredentials, CodeUnsupportedAuth, CodeCloudBedrock, CodeCloudVertex, CodeCloudFoundry,
		CodeCLIMissing, CodeUnsupportedCLI, CodeNetwork, CodeParse, CodeStorage, CodeBusy, CodeFeatureDisabled,
		CodeCancelled, CodeTimeout)
)
