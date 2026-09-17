// swift-tools-version: 6.0
import PackageDescription

// Phase 7, not yet wired up: the model layer for a future native SwiftUI front
// end over the same protocol the Python workspace implements. There is no
// @main entry point yet, so this builds as a library rather than an executable.
let package = Package(
    name: "DataLinkScanner",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DataLinkScannerApp", targets: ["DataLinkScannerApp"]),
    ],
    targets: [
        .target(name: "DataLinkScannerApp"),
        .testTarget(
            name: "DataLinkScannerAppTests",
            dependencies: ["DataLinkScannerApp"]
        ),
    ]
)
