import ArgumentParser
import Core

@available(macOS 15.0, *)
struct OpenCycleCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "open-cycle",
    abstract: "Open or focus an application, then cycle through its windows"
  )

  @Argument(help: "Application name or path (e.g., Safari or /Applications/Safari.app)")
  var appPath: String

  func run() async throws {
    try Permissions.checkAccessibility()
    // Try to resolve app name first, fall back to provided path
    let resolvedPath = ApplicationManager.resolve(appPath) ?? appPath
    let result = try ApplicationManager.openOrFocus(resolvedPath)

    if result == .opened {
      await WindowManager.main.cycleAppWindows()
    }
  }
}
