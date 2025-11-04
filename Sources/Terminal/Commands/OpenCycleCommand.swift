import ArgumentParser
import Core

struct OpenCycleCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "open-cycle",
    abstract: "Open or focus an application, then cycle through its windows"
  )

  @Argument(help: "Application name or path (e.g., Safari or /Applications/Safari.app)")
  var appPath: String

  func run() throws {
    try Permissions.checkAccessibility()
    // Try to resolve app name first, fall back to provided path
    let resolvedPath = ApplicationManager.resolve(appPath) ?? appPath
    let result = try ApplicationManager.openOrFocus(resolvedPath)

    if result == .opened {
      WindowManager.main.cycleAppWindows()
    }
  }
}
