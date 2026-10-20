// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CILocal",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "CILocal", path: "Sources/CILocal"),
        .testTarget(name: "CILocalTests", dependencies: ["CILocal"], path: "Tests/CILocalTests")
    ]
)
