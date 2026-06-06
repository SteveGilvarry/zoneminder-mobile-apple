// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZmMobileCore",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "ZmMobileCore", targets: ["ZmMobileCore"])
    ],
    targets: [
        .target(name: "ZmMobileCore"),
        .testTarget(name: "ZmMobileCoreTests", dependencies: ["ZmMobileCore"])
    ]
)
