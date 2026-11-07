// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LogoLight",
    platforms: [.macOS("27.2")],
    products: [
        .executable(name: "logoctl", targets: ["logoctl"]),
        .executable(name: "LogoLight", targets: ["LogoLight"]),
    ],
    targets: [
        .target(name: "LogoCore", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]),
        .executableTarget(name: "logoctl", dependencies: ["LogoCore"]),
        .executableTarget(name: "LogoLight", dependencies: ["LogoCore"]),
        .testTarget(name: "LogoCoreTests", dependencies: ["LogoCore"]),
    ]
)
