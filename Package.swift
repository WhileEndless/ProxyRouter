// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ProxyRouter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ProxyRouter", path: "Sources/ProxyRouter")
    ]
)
