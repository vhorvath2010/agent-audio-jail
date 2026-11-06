// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "agent-audio-jail",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "agent-audio-jail",
            path: "Sources/agent-audio-jail"
        ),
    ]
)
