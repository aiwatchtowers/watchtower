/// A card button's kind as the feed and `inbox.act press` name it
/// (`CardAction.kind`, `ActParams.actionKind`; Go `db.InboxAction.Kind`).
public enum InboxActionKind {
    public static let link = "link"
    public static let chat = "chat"
    public static let agent = "agent"
    public static let reply = "reply"
    public static let target = "target"
}
