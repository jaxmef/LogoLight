// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LogoLight",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "LogoCore", targets: ["LogoCore"]),
        .executable(name: "logoctl", targets: ["logoctl"]),
        .executable(name: "LogoLight", targets: ["LogoLight"]),
    ],
    targets: [
        .target(name: "LogoCore", exclude: ["README.md"], linkerSettings: [.linkedFramework("IOKit")]),
        // Music mode: used by the app and logoctl, not part of the library.
        .target(name: "LogoMusic", dependencies: ["LogoCore"],
                linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]),
        .executableTarget(name: "logoctl", dependencies: ["LogoCore", "LogoMusic"]),
        .executableTarget(name: "LogoLight", dependencies: ["LogoCore", "LogoMusic"]),
        .testTarget(name: "LogoLightTests", dependencies: ["LogoCore", "LogoMusic"]),
    ]
)
