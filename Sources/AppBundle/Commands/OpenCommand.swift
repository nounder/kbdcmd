import ArgumentParser

struct OpenCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "open",
    abstract: "Open or focus an application"
  )

  @Argument(help: "Application name or path (e.g., Safari or /Applications/Safari.app)")
  var appPath: String

  func run() throws {
    try Permissions.checkAccessibility()
    // Try to resolve app name first, fall back to provided path
    let resolvedPath = ApplicationManager.resolve(appPath) ?? appPath
    _ = try ApplicationManager.openOrFocus(resolvedPath)
  }
}
