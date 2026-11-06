// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Marshmallow",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Marshmallow",
            path: "Sources/Marshmallow",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))]
        )
    ]
)
