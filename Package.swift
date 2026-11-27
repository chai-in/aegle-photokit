// swift-tools-version: 6.0
// Copyright (c) 2026 chai-in
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let package = Package(
    name: "AeglePhotoKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "AeglePhotoKit", targets: ["AeglePhotoKit"])
    ],
    targets: [
        .target(name: "AeglePhotoKit"),
        .testTarget(name: "AeglePhotoKitTests", dependencies: ["AeglePhotoKit"])
    ]
)
