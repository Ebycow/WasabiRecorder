// swift-tools-version: 6.2
import PackageDescription

// Core Audio can decode MP3 but not encode it, so MP3 export links LAME
// statically (`brew install lame`), plus the mpg123 it was built against.
// Override the locations with LAME_PREFIX / MPG123_PREFIX.
let lamePrefix = Context.environment["LAME_PREFIX"] ?? "/opt/homebrew/opt/lame"
let mpg123Prefix = Context.environment["MPG123_PREFIX"] ?? "/opt/homebrew/opt/mpg123"

let package = Package(
    name: "WasabiRecorder",
    platforms: [.macOS(.v26)],
    targets: [
        .systemLibrary(name: "CLame", path: "Sources/CLame"),
        .executableTarget(
            name: "WasabiRecorder",
            dependencies: ["CLame"],
            path: "Sources/WasabiRecorder",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Xcc", "-I\(lamePrefix)/include"]),
            ],
            linkerSettings: [.unsafeFlags(["\(lamePrefix)/lib/libmp3lame.a", "\(mpg123Prefix)/lib/libmpg123.a"])]
        )
    ]
)
