// swift-tools-version: 5.10

import PackageDescription

// The tower interface's Swift side, shared by the Mac and the iPhone (mobile
// Inbox spec §2.3, #1170): the types generated from internal/tower/api
// (Sources/WatchtowerInterface/Generated, `make gen-interface`) and the
// hand-written pieces they use. Foundation only and no package dependencies,
// so WatchtowerCore (which stays Kit-free) and the phone both link it.
let package = Package(
    name: "WatchtowerInterface",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WatchtowerInterface", targets: ["WatchtowerInterface"]),
    ],
    targets: [
        .target(name: "WatchtowerInterface"),
        .testTarget(
            name: "WatchtowerInterfaceTests",
            dependencies: ["WatchtowerInterface"]
        ),
    ]
)
