// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "molly",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "molly", targets: ["Molly"])
    ],
    targets: [
        .executableTarget(
            name: "Molly",
            path: "Sources/Molly",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "MollyTests",
            dependencies: ["Molly"],
            path: "Tests/MollyTests"
        ),
    ]
)
