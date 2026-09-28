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
            dependencies: ["BrowserKit", "InspectKit", "PasswordKit", "TranslateKit", "UpdateKit", "DataKit", "BlockKit"],
            resources: [.copy("DevToolsUI"), .copy("PasswordAgent"), .copy("TranslateAgent"), .copy("PageMenuAgent"), .copy("ReaderAgent"), .copy("AppIcon")],
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
        // Page translation through Google Translate: languages, batching,
        // the request and its response. Foundation only.
        .target(name: "TranslateKit", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(
            name: "TranslateKitChecks",
            dependencies: ["TranslateKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The browser's own data on disk: history, bookmarks. SQLite from the
        // system, so no dependency to fetch.
        .target(name: "DataKit", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(
            name: "DataKitChecks",
            dependencies: ["DataKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Self-update: versions, GitHub's release answer, Ed25519 signatures.
        .target(name: "UpdateKit", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(
            name: "UpdateKitChecks",
            dependencies: ["UpdateKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Signs a release DMG in CI: `swift run SignUpdate <file>` with the key in UPDATE_SIGNING_KEY.
        .executableTarget(
            name: "SignUpdate",
            dependencies: ["UpdateKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // `swift run BrowserKitChecks`: the profile roster's rules, same arrangement.
        .executableTarget(
            name: "BrowserKitChecks",
            dependencies: ["BrowserKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // `swift run BlockKitChecks`: the filter parser, and exceptions across partitions.
        .executableTarget(
            name: "BlockKitChecks",
            dependencies: ["BlockKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "BlockKitTests", dependencies: ["BlockKit"]),
    ]
)
