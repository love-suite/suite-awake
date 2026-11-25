// swift-tools-version:5.9
import PackageDescription

// The GitHub organization of the suite's repositories: the one name to change should it be renamed (the
// suite repository's scripts/rename-organization.sh does it in every repository).
let organization = "love-suite"

// Awake: keeps the Mac awake, for a while or until stopped, optionally with the lid closed or with the
// screen off. Its logic stays UI-free in AwakeCore; its settings are a library of their own, which Suite
// Settings can read for an Awake tab. Lid sleep, which a closed-lid session turns off, is turned back on by
// Suite Guard should Awake vanish (`ClamshellGuard`).
let package = Package(
    name: "Awake",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AwakeSettings", targets: ["AwakeSettings"]),
    ],
    dependencies: [
        .package(url: "https://github.com/\(organization)/suite-core", .upToNextMinor(from: "27.1.0-dev.1")),
        .package(url: "https://github.com/\(organization)/suite-guard", .upToNextMinor(from: "27.1.0-dev.1")),
    ],
    targets: [
        .target(name: "AwakeSettings"),
        .target(name: "AwakeCore", dependencies: ["AwakeSettings"]),
        .executableTarget(
            name: "Awake",
            dependencies: ["AwakeCore", "AwakeSettings", .product(name: "SuiteCore", package: "suite-core"),
                           .product(name: "ClamshellGuard", package: "suite-guard")],
            resources: [.process("Resources")],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement"),
                             .linkedFramework("UserNotifications")]
        ),
        .testTarget(name: "AwakeCoreTests", dependencies: ["AwakeCore", "AwakeSettings"]),
    ]
)
