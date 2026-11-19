import WatchtowerChatText

/// Where a pasted image or text goes (#2065 §6). With `inlinePastes` (the Workchat) an image and a text of
/// `PasteClassifier.longTextThreshold` characters or more go into the field as a token; without it (the AI chat) an
/// image is a chip and a long text gets the "Attach as file" offer. A shorter text is inserted as it is either way.
public enum ComposerPasteRoute: Equatable {
    case plain, offerAsFile, token, chip

    public static func route(isImage: Bool, characterCount: Int, inlinePastes: Bool) -> Self {
        if isImage { return inlinePastes ? .token : .chip }
        guard characterCount >= PasteClassifier.longTextThreshold else { return .plain }
        return inlinePastes ? .token : .offerAsFile
    }
}
