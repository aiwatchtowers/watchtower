package db

// AskExplainContextType is the chat_conversations.context_type of a "Not
// clear?" chat on an ask (spec 2026-11-24-ask-explain-chat): its context_id is
// `<workbench id>:<ask id>`. The chat explains one question to the owner and
// stays on that ask's panel, so it is never mined for knowledge, history or
// memory, goes with its workbench, and follows it on a merge.
const AskExplainContextType = "owner_ask_explain"
