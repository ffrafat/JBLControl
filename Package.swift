// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "JBLControl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "JBLControl", targets: ["JBLControl"]),
        .library(name: "JBLControlKit", targets: ["JBLControlKit"]),
    ],
    targets: [
        // Pure protocol + model catalog: no CoreBluetooth, fully unit-testable.
        .target(name: "JBLControlKit"),
        // The menu bar app. Bundled into JBLControl.app by scripts/build-app.sh.
        .executableTarget(
            name: "JBLControl",
            dependencies: ["JBLControlKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "JBLControlKitTests", dependencies: ["JBLControlKit"]),
    ]
)
