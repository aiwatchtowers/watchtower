package blocks

// Document caps (Inbox builder A spec, "Document caps").
const (
	// MaxBlocks caps the blocks of one document.
	MaxBlocks = 40
	// MaxRows caps the list and table rows of one document, in all.
	MaxRows = 500
	// MaxActions caps the card's flattened action list (card actions
	// included).
	MaxActions = 50
	// MaxBlocksBytes caps the canonical document, in bytes.
	MaxBlocksBytes = 128 * 1024
	// MaxTextBytes caps a text block's markdown, in bytes.
	MaxTextBytes = 16 * 1024
)

// Per-field limits, in characters (runes) unless marked bytes.
const (
	MaxHeadingChars      = 200
	MaxListTitleChars    = 200
	MaxListRows          = 200
	MaxListEmptyChars    = 200
	MaxRowTitleChars     = 300
	MaxRowSubtitleChars  = 500
	MaxBadgeChars        = 40
	MaxRowActions        = 3
	MaxTableTitleChars   = 200
	MaxColumns           = 6
	MaxColumnTitleChars  = 60
	MaxTableRows         = 100
	MaxCellChars         = 200
	MaxPersonNameChars   = 120
	MaxPersonRoleChars   = 120
	MaxPersonLines       = 10
	MaxPersonLineChars   = 300
	MaxSlackUserChars    = 200
	MaxMetrics           = 6
	MaxMetricLabelChars  = 40
	MaxMetricValueChars  = 24
	MaxMetricHintChars   = 120
	MaxLinkTitleChars    = 200
	MaxLinkSubtitleChars = 300
	MaxBlockActions      = 4
)

// The action grammar's limits (card actions and block actions alike).
const (
	// MaxCardActions caps a card's own actions.
	MaxCardActions = 4
	// MaxActionLabelChars caps an action's label, in characters.
	MaxActionLabelChars = 40
	// MaxActionTextBytes caps a chat action's first message and an agent
	// action's task.
	MaxActionTextBytes = 4 * 1024
	// MaxActionDataBytes caps a reply action's data, as canonical JSON.
	MaxActionDataBytes = 8 * 1024
	// MaxLinkBytes caps a card URL (the card's link, a link action's open,
	// a row's or a block's link).
	MaxLinkBytes = 2048
	// MaxReplyValueChars caps a reply action's value, in characters.
	MaxReplyValueChars = 100
	// MaxTargetTitleChars caps a target action's title (create_target's
	// text limit).
	MaxTargetTitleChars = 200
	// MaxTargetIntentChars caps a target action's intent.
	MaxTargetIntentChars = 1000
)

// DefaultListEmpty is a list's empty text when the script gives none.
const DefaultListEmpty = "Nothing here"
