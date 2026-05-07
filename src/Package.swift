// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BeatsBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "BeatsBar",
            path: "Sources/BeatsBar",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "aacp_helper",
            path: "Sources/aacp_helper"
        )
    ]
)
