// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ANChor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ANChor",
            path: "Sources/ANChor",
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("Cocoa"),
            ]
        ),
    ]
)
