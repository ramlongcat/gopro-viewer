// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GoProOffload",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GoProOffload",
            path: "Sources/GoProOffload",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AVKit"), .linkedFramework("MapKit")]
        )
    ]
)
