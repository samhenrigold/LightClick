// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GuestControl",
    platforms: [.macOS(.v15)],
    products: [.library(name: "GuestControl", type: .static, targets: ["GuestControl"])],
    targets: [
        .target(name: "GuestControl", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "GuestControlTests", dependencies: ["GuestControl"], swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
