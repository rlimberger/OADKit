// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "OADKit",
    platforms: [
        .iOS(.v12),
        .macOS(.v10_13)
    ],
    products: [
        .library(name: "OADKit", targets: ["OADKit"])
    ],
    targets: [
        .target(
            name: "OADKit",
            path: "OADKit"
        )
    ]
)
