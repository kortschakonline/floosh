// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Floosh",
    platforms: [
        // Ab macOS 14 lauffähig (Intel-Macs/Hackintoshes); Liquid Glass
        // gibt es ab macOS 26, davor greift die Material-Optik (GlassCompat)
        .macOS("14.0")
    ],
    targets: [
        // Gemeinsamer SMC-Zugriff + XPC-Protokoll für App und Helper
        .target(
            name: "FlooshShared",
            path: "Sources/FlooshShared"
        ),
        .executableTarget(
            name: "Floosh",
            dependencies: ["FlooshShared"],
            path: "Sources/Floosh"
        ),
        // Privilegierter Helper (LaunchDaemon) für Lüfter-Schreibzugriff
        .executableTarget(
            name: "FlooshFanHelper",
            dependencies: ["FlooshShared"],
            path: "Sources/FlooshFanHelper"
        ),
    ]
)
