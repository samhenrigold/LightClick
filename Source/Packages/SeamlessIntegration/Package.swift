// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "SeamlessIntegration",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SeamlessIntegration", type: .static, targets: ["SeamlessIntegration"]),
        .executable(name: "SeamlessProxy", targets: ["SeamlessProxy"]),
        .executable(name: "SeamlessMakeProxy", targets: ["SeamlessMakeProxy"]),
        .executable(name: "seamless-integration-probe", targets: ["SeamlessIntegrationProbe"])
    ],
    targets: [
        .target(name: "SeamlessIntegration", swiftSettings: settings),
        .target(name: "SeamlessInputKit", cSettings: [.unsafeFlags(["-fobjc-arc", "-Wno-deprecated-declarations"])]),
        .executableTarget(
            name: "SeamlessProxy", dependencies: ["SeamlessIntegration", "SeamlessInputKit"], swiftSettings: settings),
        .executableTarget(name: "SeamlessMakeProxy", dependencies: ["SeamlessIntegration"], swiftSettings: settings),
        .executableTarget(
            name: "SeamlessIntegrationProbe", dependencies: ["SeamlessIntegration"], swiftSettings: settings),
        .testTarget(
            name: "SeamlessIntegrationTests", dependencies: ["SeamlessIntegration"], swiftSettings: settings)
    ]
)
