// swift-tools-version: 6.0
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
    // Runs the swift-testing suite as a plain executable (`swift run
    // kbdcmd-tests`): the Command Line Tools ship Testing.framework outside
    // SwiftPM's default search paths and lack the XCTest harness needed to
    // host a regular .testTarget bundle.
    .executableTarget(
      name: "kbdcmd-tests",
      dependencies: ["Core"],
      path: "Tests/CoreTests",
      swiftSettings: [
        .unsafeFlags([
          "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
        ])
      ],
      linkerSettings: [
        .unsafeFlags([
          "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
          "-Xlinker", "-rpath",
          "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
        ])
      ]
    ),
  ],
  swiftLanguageModes: [.v5]
)
