// swift-tools-version: 6.0
// InstallerKit: the installer catalog, its source policy and resumable downloads. No third-party dependencies.
import PackageDescription

let package = Package(
    name: "InstallerKit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "InstallerKit", targets: ["InstallerKit"])],
    targets: [
        .target(name: "InstallerKit"),
        .testTarget(name: "InstallerKitTests", dependencies: ["InstallerKit"])
    ],
    swiftLanguageModes: [.v6]
)
