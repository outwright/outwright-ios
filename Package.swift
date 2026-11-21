// swift-tools-version: 6.2
// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The layers below are enforced by the package itself: a module can only import what its
// target lists as a dependency. Keep the graph as it is drawn in AGENTS.md.
// OutwrightFakes is test support and is never a dependency of a product target.

import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "Outwright",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "OutwrightUI", targets: ["OutwrightUI"]),
        // The notification service extension finds new mail with it, without the interface.
        .library(name: "OutwrightSync", targets: ["OutwrightSync"]),
        // The integration tests (TESTING.md) read the test server's state back with the real client.
        .library(name: "OutwrightIMAP", targets: ["OutwrightIMAP", "OutwrightNet"]),
        // ... and the contacts the same way, over CardDAV.
        .library(name: "OutwrightDAV", targets: ["OutwrightDAV"]),
        // What a package that builds on this one (a provider) speaks and stores through.
        .library(name: "OutwrightModel", targets: ["OutwrightModel"]),
        .library(name: "OutwrightStore", targets: ["OutwrightStore"]),
        .library(name: "OutwrightMIME", targets: ["OutwrightMIME"]),
        .library(name: "OutwrightGraph", targets: ["OutwrightGraph"]),
        .library(name: "OutwrightNet", targets: ["OutwrightNet"]),
        .library(name: "OutwrightPush", targets: ["OutwrightPush"]),
        .library(name: "OutwrightSetup", targets: ["OutwrightSetup"]),
        .library(name: "OutwrightSMTP", targets: ["OutwrightSMTP"]),
        // The fakes, for the tests of a package that builds on this one.
        .library(name: "OutwrightFakes", targets: ["OutwrightFakes"]),
        // A fake Microsoft (sign-in, Graph, IMAP and SMTP) on this Mac, for the end-to-end tests.
        .executable(name: "outwright-fake-microsoft", targets: ["OutwrightFakeMicrosoft"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        // L0: connections and Internet messages, no model.
        .target(name: "OutwrightNet", swiftSettings: strict),
        .target(name: "OutwrightMIME", swiftSettings: strict),
        // L1: the protocols, and the model with its edits (no I/O).
        .target(name: "OutwrightIMAP", dependencies: ["OutwrightNet", "OutwrightMIME"], swiftSettings: strict),
        .target(name: "OutwrightSMTP", dependencies: ["OutwrightNet", "OutwrightMIME"], swiftSettings: strict),
        .target(name: "OutwrightDAV", dependencies: ["OutwrightNet"], swiftSettings: strict),
        .target(name: "OutwrightGraph", dependencies: ["OutwrightNet"], swiftSettings: strict),
        .target(name: "OutwrightPush", dependencies: ["OutwrightNet"], swiftSettings: strict),
        .target(name: "OutwrightSetup", resources: [.process("Resources")], swiftSettings: strict),
        .target(name: "OutwrightJMAP", dependencies: ["OutwrightNet"], swiftSettings: strict),
        .target(name: "OutwrightModel", dependencies: ["OutwrightMIME"], swiftSettings: strict),
        // L2: SQLite storage of the model.
        .target(name: "OutwrightStore", dependencies: ["OutwrightModel", "OutwrightMIME", .product(name: "GRDB", package: "GRDB.swift")], swiftSettings: strict),
        // L3: synchronisation between protocols, store and model.
        .target(name: "OutwrightSync", dependencies: ["OutwrightNet", "OutwrightMIME", "OutwrightModel", "OutwrightStore", "OutwrightIMAP", "OutwrightSMTP", "OutwrightDAV", "OutwrightGraph", "OutwrightPush", "OutwrightJMAP", "OutwrightSetup"], swiftSettings: strict),
        // L4: SwiftUI; reads Model, Store and Sync, never speaks a protocol.
        .target(
            name: "OutwrightUI", dependencies: ["OutwrightModel", "OutwrightMIME", "OutwrightStore", "OutwrightSync", "OutwrightPush", "OutwrightSetup"],
            resources: [.process("Resources")], swiftSettings: strict),
        // Test support: in-process fake servers, never a dependency of a product target.
        .target(name: "OutwrightFakes", dependencies: ["OutwrightNet", "OutwrightMIME", "OutwrightSetup"], swiftSettings: strict),
        .executableTarget(name: "OutwrightFakeMicrosoft", dependencies: ["OutwrightFakes"], swiftSettings: strict),
        // Tests, one target per module.
        .testTarget(name: "OutwrightNetTests", dependencies: ["OutwrightNet", "OutwrightFakes"], swiftSettings: strict),
        .testTarget(name: "OutwrightMIMETests", dependencies: ["OutwrightMIME", "OutwrightFakes"], swiftSettings: strict),
        .testTarget(name: "OutwrightIMAPTests", dependencies: ["OutwrightIMAP", "OutwrightFakes"], swiftSettings: strict),
        .testTarget(name: "OutwrightSMTPTests", dependencies: ["OutwrightSMTP", "OutwrightFakes"], swiftSettings: strict),
        .testTarget(name: "OutwrightDAVTests", dependencies: ["OutwrightDAV", "OutwrightFakes"], swiftSettings: strict),
        .testTarget(name: "OutwrightGraphTests", dependencies: ["OutwrightGraph", "OutwrightFakes", "OutwrightNet"], swiftSettings: strict),
        .testTarget(name: "OutwrightPushTests", dependencies: ["OutwrightPush", "OutwrightFakes"], swiftSettings: strict),
        .testTarget(
            name: "OutwrightSetupTests", dependencies: ["OutwrightSetup", "OutwrightFakes"], resources: [.copy("Fixtures")],
            swiftSettings: strict),
        .testTarget(
            name: "OutwrightJMAPTests", dependencies: ["OutwrightJMAP", "OutwrightFakes", "OutwrightNet", "OutwrightPush"],
            swiftSettings: strict),
        .testTarget(name: "OutwrightModelTests", dependencies: ["OutwrightModel", "OutwrightMIME"], swiftSettings: strict),
        .testTarget(name: "OutwrightStoreTests", dependencies: ["OutwrightStore", "OutwrightModel", "OutwrightMIME"], swiftSettings: strict),
        .testTarget(
            name: "OutwrightSyncTests",
            dependencies: [
                "OutwrightSync", "OutwrightFakes", "OutwrightModel", "OutwrightStore", "OutwrightMIME", "OutwrightNet", "OutwrightIMAP",
                "OutwrightDAV", "OutwrightPush", "OutwrightJMAP", "OutwrightGraph", "OutwrightSMTP", "OutwrightSetup", .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: strict),
        .testTarget(
            name: "OutwrightUITests",
            dependencies: [
                "OutwrightUI", "OutwrightModel", "OutwrightMIME", "OutwrightStore", "OutwrightSync", "OutwrightNet",
                "OutwrightFakes", "OutwrightPush", "OutwrightDAV", "OutwrightSetup",
            ],
            swiftSettings: strict),
    ]
)
