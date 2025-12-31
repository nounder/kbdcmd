// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "kbdcmd",
  platforms: [.macOS("15.0")],
  products: [
    .library(name: "Core", targets: ["Core"]),
    .executable(name: "kbdcmd", targets: ["Terminal"]),
    .executable(name: "kbdcmd-app", targets: ["Desktop"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
  ],
  targets: [
    .target(
      name: "Core",
      dependencies: [],
      path: "Sources/Core"
    ),
    .executableTarget(
      name: "Terminal",
      dependencies: [
        "Core",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "Sources/Terminal"
    ),
    .executableTarget(
      name: "Desktop",
      dependencies: ["Core"],
      path: "Sources/Desktop",
      exclude: ["Resources"]
    ),
  ]
)
