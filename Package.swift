// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrilioPrototype",
    platforms: [.macOS("14.6")],
    targets: [
        .executableTarget(name: "OrilioPrototype"),
        .testTarget(name: "OrilioPrototypeTests", dependencies: ["OrilioPrototype"]),
    ]
)
