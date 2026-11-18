// swift-tools-version: 5.10

import PackageDescription

// The chat shared by the Mac and the iPhone (unified chat spec §6.1, D8):
// - ChatWire: Foundation (plus CryptoKit for the approval card's args digest,
//   unified chat T15) — the chat wire models (moved out of the mobile
//   Kit), the operations, the `ChatClient` protocol, the feed and list stores
//   and the flat-fields → parts adapter. It imports nothing of ours, so
//   WatchtowerCore (which stays Kit-free) and the phone both link it.
// - ChatUI: the chat views and their models, on ChatWire, WatchtowerChatText
//   and the Kit's design tokens (T7). Platform parts live in
//   Sources/ChatUI/Platform/{macOS,iOS} behind `#if os(...)` (D9).
// The Kit does not depend on this package (spec §14: ChatUI needs the Kit's
// WatchtowerDesign, so the reverse edge would be a cycle); the Kit-only
// conformances of the chat models (`SliceMirror`, `ActionParams`) live in the
// phone app.
let package = Package(
    name: "WatchtowerChat",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "ChatWire", targets: ["ChatWire"]),
        .library(name: "ChatUI", targets: ["ChatUI"]),
    ],
    dependencies: [
        .package(path: "../WatchtowerKit"),
        .package(path: "../WatchtowerChatText"),
    ],
    targets: [
        .target(name: "ChatWire"),
        .target(
            name: "ChatUI",
            dependencies: [
                "ChatWire",
                .product(name: "WatchtowerChatText", package: "WatchtowerChatText"),
                .product(name: "WatchtowerDesign", package: "WatchtowerKit"),
            ]
        ),
        .testTarget(
            name: "ChatWireTests",
            dependencies: [
                "ChatWire",
                // Test only: the wire coder is checked against RelayCoder.
                .product(name: "WatchtowerSync", package: "WatchtowerKit"),
            ]
        ),
        .testTarget(
            name: "ChatUITests",
            dependencies: [
                "ChatUI",
                "ChatWire",
                .product(name: "WatchtowerChatText", package: "WatchtowerChatText"),
            ]
        ),
    ]
)
