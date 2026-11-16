// swift-tools-version: 5.10

import PackageDescription

// The chat text helpers shared by the Mac and the iPhone (iPhone chat spec D8,
// #1791): the artifact parser, the Markdown document and run builder, and the
// quote-reply composer. Pure Foundation plus swift-markdown; it is neither
// WatchtowerCore (which stays Kit-free) nor the mobile Kit (which carries
// GRDB), so Core and the phone both link it.
let package = Package(
    name: "WatchtowerChatText",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WatchtowerChatText", targets: ["WatchtowerChatText"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
    ],
    targets: [
        .target(
            name: "WatchtowerChatText",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .testTarget(
            name: "WatchtowerChatTextTests",
            dependencies: ["WatchtowerChatText"]
        ),
    ]
)
