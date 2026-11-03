// swift-tools-version: 6.1

import PackageDescription

// Three layers, and the GPL lives in exactly one of them:
//
//   XPCWhatsMeow             what an app links: a typed client. No whatsmeow inside.
//   XPCWhatsMeowProtocol     the XPC interface both sides share. No whatsmeow inside.
//   XPCWhatsMeowServiceKit   what the XPC service links: whatsmeow (Go) behind a C ABI.
//
// Only a binary built from XPCWhatsMeowServiceKit contains whatsmeow and its GPLv3
// dependency libsignal, and that binary is the XPC service: a separate process. See NOTICE.
let package = Package(
    name: "XPCWhatsMeowService",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "XPCWhatsMeow", targets: ["XPCWhatsMeow"]),
        .library(name: "XPCWhatsMeowProtocol", targets: ["XPCWhatsMeowProtocol"]),
        .library(name: "XPCWhatsMeowServiceKit", targets: ["XPCWhatsMeowServiceKit"]),
    ],
    targets: [
        // Built by scripts/build-xcframework.sh from Go/wabridge. Not checked in.
        .binaryTarget(
            name: "CWhatsMeow",
            path: "Frameworks/CWhatsMeow.xcframework"
        ),
        .target(name: "XPCWhatsMeowProtocol"),
        .target(
            name: "XPCWhatsMeow",
            dependencies: ["XPCWhatsMeowProtocol"]
        ),
        .target(
            name: "XPCWhatsMeowServiceKit",
            dependencies: ["CWhatsMeow", "XPCWhatsMeowProtocol"]
        ),
        // The client against a mock service — no Go, no network.
        .testTarget(
            name: "XPCWhatsMeowTests",
            dependencies: ["XPCWhatsMeow", "XPCWhatsMeowProtocol"]
        ),
        // The real Go library, directly and over a real XPC connection.
        .testTarget(
            name: "XPCWhatsMeowServiceKitTests",
            dependencies: ["XPCWhatsMeowServiceKit", "XPCWhatsMeow", "XPCWhatsMeowProtocol"]
        ),
    ]
)
