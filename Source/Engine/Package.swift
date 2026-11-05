// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Engine",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Engine", type: .static, targets: ["Engine"]),
        .executable(name: "engine-run", targets: ["engine-run"]),
    ],
    targets: [
        .target(name: "CEngine", cSettings: [.unsafeFlags(["-march=armv8.5-a+crc"])]),
        .target(
            name: "Engine", dependencies: ["CEngine"],
            linkerSettings: [.linkedFramework("Hypervisor")]),
        .executableTarget(name: "engine-run", dependencies: ["Engine", "CEngine"]),
    ]
)
