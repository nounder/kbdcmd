import Testing

// The Command Line Tools have no XCTest harness to host a .xctest bundle, so
// the suite runs as a plain executable through swift-testing's entry point:
// `swift run kbdcmd-tests`.
@main struct TestMain {
  static func main() async {
    await Testing.__swiftPMEntryPoint() as Never
  }
}
