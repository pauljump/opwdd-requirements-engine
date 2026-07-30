// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OPWDDRequirements",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "OPWDDRequirements", targets: ["OPWDDRequirements"])
    ],
    targets: [
        .target(
            name: "OPWDDRequirements",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "OPWDDRequirementsTests",
            dependencies: ["OPWDDRequirements"]
        )
    ]
)
