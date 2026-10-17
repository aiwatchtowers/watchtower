package automations

const SlackReactionAdded = "slack.reaction_added"

// ReactionEvent is one slack.reaction_added event: the owner reacted to a
// message. Ids, labels and the bare emoji short name only — never the message
// text, its author or the channel name.
func ReactionEvent(account, channelID, messageTS, emoji string) Event {
	return Event{Type: SlackReactionAdded, Fields: map[string]any{
		"account": account, "channel_id": channelID, "message_ts": messageTS, "emoji": emoji,
	}}
}
