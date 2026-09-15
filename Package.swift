// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MusicLab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MusicLab", path: "Sources/MusicLab")
    ]
)
