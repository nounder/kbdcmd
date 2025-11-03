import ArgumentParser

struct OpenCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "open",
    abstract: "Open or focus an application"
  )

  @Argument(help: "Path to the application (e.g., /Applications/Safari.app)")
  var appPath: String

  func run() throws {
    try Permissions.checkAccessibility()
    _ = try ApplicationManager.openOrFocus(appPath)
  }
}
