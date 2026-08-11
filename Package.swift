// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SmsCodeMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SmsCodeCore", targets: ["SmsCodeCore"]),
        .executable(name: "SmsCodeMenuBar", targets: ["SmsCodeMenuBar"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "SmsCodeCore",
            dependencies: ["CSQLite"]
        ),
        .executableTarget(
            name: "SmsCodeMenuBar",
            dependencies: ["SmsCodeCore"]
        ),
        .testTarget(
            name: "SmsCodeCoreTests",
            dependencies: ["SmsCodeCore", "CSQLite"]
        ),
        .testTarget(
            name: "SmsCodeMenuBarTests",
            dependencies: ["SmsCodeMenuBar", "SmsCodeCore"]
        )
    ]
)
