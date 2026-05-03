// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dixie",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Dixie", targets: ["DixieApp"])
    ],
    targets: [
        .executableTarget(
            name: "DixieApp",
            dependencies: [],
            path: "Sources"
        )
    ]
)