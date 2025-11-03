import ArgumentParser

struct OpenCycleCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "open-cycle",
    abstract: "Open or focus an application, then cycle through its windows"
  )

  @Argument(help: "Path to the application (e.g., /Applications/Safari.app)")
  var appPath: String

  func run() throws {
    try Permissions.checkAccessibility()
    let result = try ApplicationManager.openOrFocus(appPath)

    if result == .opened {
      WindowManager.main.cycleAppWindows()
    }
  }
}
