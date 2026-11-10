// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DurableChat",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DurableChat", targets: ["DurableChatApp"]),
        .library(name: "ChatCore", targets: ["ChatCore"]),
        .library(name: "ChatUI", targets: ["ChatUI"]),
        .library(name: "AgentRuntime", targets: ["AgentRuntime"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/finnvoor/PiDurableKit",
            revision: "4e1120bbdc7c5329a2f3c05a22bec4b9c9a076bb"
        ),
    ],
    targets: [
        .target(name: "ChatCore"),
        .target(name: "ChatUI", dependencies: ["ChatCore"]),
        .target(name: "AgentRuntime", dependencies: [
            "ChatCore", .product(name: "PiDurableKit", package: "PiDurableKit"),
        ]),
        .executableTarget(name: "DurableChatApp", dependencies: ["ChatCore", "ChatUI", "AgentRuntime"]),
        .testTarget(name: "ChatCoreTests", dependencies: ["ChatCore"]),
        .testTarget(name: "ChatUITests", dependencies: ["ChatUI", "ChatCore"]),
        .testTarget(name: "AgentRuntimeTests", dependencies: ["AgentRuntime", "ChatCore"]),
    ],
    swiftLanguageModes: [.v6]
)
