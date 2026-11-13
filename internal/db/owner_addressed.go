package db

import "strings"

// The "addressed to the owner" rules shared by the attention detector
// (FindPendingMentions, FindThreadRepliesToUser, FindReactionRequests) and the
// Slack window's ToOwner flag (ReadSlackWindow). One SQL text per rule, so the
// two readers cannot drift apart. Each helper returns a parenthesised boolean
// SQL expression with `?` placeholders; the caller binds them in the order the
// helper documents. The 1:1 DM rule (`channels.type = 'dm'`, from another
// person) has no helper: it is a channel-type check each reader states inline.

// AttentionReactionEmoji are the reactions another person places on the
// owner's message to ask for the owner's attention (a reaction request).
var AttentionReactionEmoji = []string{"question", "grey_question", "eyes", "bangbang", "exclamation", "heavy_exclamation_mark", "warning", "red_circle", "rotating_light", "sos"}

// attentionEmojiList is AttentionReactionEmoji as an SQL `IN` list. The values
// are compile-time constants, never Slack data.
var attentionEmojiList = func() string {
	quoted := make([]string, len(AttentionReactionEmoji))
	for i, e := range AttentionReactionEmoji {
		quoted[i] = "'" + e + "'"
	}
	return "(" + strings.Join(quoted, ", ") + ")"
}()

// ownerMentionSQL matches a message text that mentions the owner in either of
// Slack's forms, `<@RAW>` or `<@RAW|Display Name>` (the boundary character
// keeps ids sharing a prefix apart). Binds, in order: the strict and the pipe
// pattern of slack.MentionPatterns(ownerID).
func ownerMentionSQL(textCol string) string {
	return "(" + textCol + " LIKE ? OR " + textCol + " LIKE ?)"
}

// ownerThreadReplySQL matches a reply (not a thread root) in a thread where the
// owner has another message, root or reply. alias is the messages alias.
// Binds, in order: the owner's namespaced user id.
func ownerThreadReplySQL(alias string) string {
	return `(` + alias + `.thread_ts != ''
		  AND ` + alias + `.thread_ts != ` + alias + `.ts
		  AND EXISTS (
		      SELECT 1 FROM messages participant
		      WHERE participant.channel_id = ` + alias + `.channel_id
		        AND participant.thread_ts = ` + alias + `.thread_ts
		        AND participant.user_id = ?
		        AND participant.ts != ` + alias + `.ts
		  ))`
}

// ownerReactionRequestSQL matches the owner's own message on which another
// person placed one of AttentionReactionEmoji. alias is the messages alias.
// Binds, in order: the owner's namespaced user id (the author), the owner's
// namespaced user id (excluded as the reactor).
func ownerReactionRequestSQL(alias string) string {
	return `(` + alias + `.user_id = ? AND EXISTS (
		      SELECT 1 FROM reactions ar WHERE ` + attentionReactionMatchSQL("ar", alias) + `))`
}

// attentionReactionMatchSQL is the reaction half of ownerReactionRequestSQL:
// a reactions row (reactionAlias) on the message msgAlias, by someone other
// than the owner, with an attention emoji. Binds: the owner's namespaced id.
// FindReactionRequests also uses it to name the reactor.
func attentionReactionMatchSQL(reactionAlias, msgAlias string) string {
	return reactionAlias + `.channel_id = ` + msgAlias + `.channel_id
		        AND ` + reactionAlias + `.message_ts = ` + msgAlias + `.ts
		        AND ` + reactionAlias + `.user_id != ?
		        AND ` + reactionAlias + `.emoji IN ` + attentionEmojiList
}
