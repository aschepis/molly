// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MollyHealthCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "MollyHealthCore", targets: ["MollyHealthCore"])],
    targets: [
        .target(name: "MollyHealthCore"),
        .testTarget(name: "MollyHealthCoreTests", dependencies: ["MollyHealthCore"]),
    ]
)
