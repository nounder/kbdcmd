// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "kbdcmd",
  platforms: [.macOS(.v12)],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
  ],
  targets: [
    .executableTarget(
      name: "kbdcmd",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ]
    )
  ]
)
