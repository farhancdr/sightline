// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Sightline",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sightline", targets: ["Sightline"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", .upToNextMinor(from: "1.20.0")),
    ],
    targets: [
        .executableTarget(
            name: "Sightline",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Sightline"
        ),
        .testTarget(
            name: "SightlineTests",
            dependencies: ["Sightline"],
            path: "Tests/SightlineTests"
        ),
    ]
)
