// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Savo",
    defaultLocalization: "en",   // язык отката для неподдерживаемых языков системы
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Savo",
            path: "Sources/Savo",
            resources: [.process("Resources")]
        )
    ]
)
