// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimpleBrowser",
    platforms: [.macOS("15.4")],
    products: [
        .executable(name: "SimpleBrowser", targets: ["BrowserApp"]),
        .library(name: "BrowserKit", targets: ["BrowserKit"]),
        .library(name: "BlockKit",   targets: ["BlockKit"]),
        .library(name: "InspectKit", targets: ["InspectKit"]),
        .library(name: "PasswordKit", targets: ["PasswordKit"]),
    ],
    targets: [
        // The only target allowed to import AppKit / WebKit. Everything it
        // needs from the model layer comes through BrowserKit and InspectKit.
        .executableTarget(
            name: "BrowserApp",
            dependencies: ["BrowserKit", "InspectKit", "PasswordKit"],
            resources: [.copy("DevToolsUI"), .copy("PasswordAgent")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Pure Foundation. No WebKit, no AppKit. Buildable and testable on any
        // platform with a Swift toolchain -- which is the point.
        .target(name: "BrowserKit", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "BlockKit",   swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(
            name: "InspectKit",
            dependencies: ["BrowserKit"],
            resources: [
                .copy("Resources/dom-agent.js"),
                .copy("Resources/agent.js"),
                .copy("Resources/page-hooks.js"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Saved sign-ins: the encrypted vault, origin matching, the save /
        // update rules, the generator and CSV. Foundation, CryptoKit and
        // Security only, so all of it is checkable without a web view.
        .target(name: "PasswordKit", swiftSettings: [.swiftLanguageMode(.v6)]),
        // `swift run PasswordKitChecks`: unit checks as a plain executable,
        // because a Command Line Tools-only Mac has no XCTest.
        .executableTarget(
            name: "PasswordKitChecks",
            dependencies: ["PasswordKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "BlockKitTests", dependencies: ["BlockKit"]),
    ]
)
