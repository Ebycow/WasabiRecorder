// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WasabiRecorder",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "WasabiRecorder",
            path: "Sources/WasabiRecorder",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
