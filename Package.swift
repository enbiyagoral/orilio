// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import PackageDescription

let package = Package(
    name: "OrilioPrototype",
    platforms: [.macOS("14.6")],
    dependencies: [
        // Signed, verified self-updates (EdDSA). The only third-party dependency.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "OrilioPrototype",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            // The app bundle keeps Sparkle.framework in Contents/Frameworks (see scripts/make-app.sh).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "OrilioPrototypeTests", dependencies: ["OrilioPrototype"]),
    ]
)
