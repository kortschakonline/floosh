// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Floosh",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "Floosh",
            path: "Sources/Floosh"
        )
    ]
)
