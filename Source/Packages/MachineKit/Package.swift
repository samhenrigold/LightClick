// swift-tools-version: 6.0
// MachineKit: the machine model. Machine.plist as a value, the rules it must satisfy, and the pure checks on guest
// reports and installation journals. No file locks and no third-party dependencies; `Guest` comes from InstallerKit.
import PackageDescription

let package = Package(
    name: "MachineKit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MachineKit", type: .static, targets: ["MachineKit"])],
    dependencies: [.package(path: "../InstallerKit")],
    targets: [
        .target(name: "MachineKit", dependencies: ["InstallerKit"]),
        .testTarget(name: "MachineKitTests", dependencies: ["MachineKit"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)
