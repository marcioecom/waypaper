// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Waypaper",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "Waypaper", resources: [.process("Resources")])]
)
