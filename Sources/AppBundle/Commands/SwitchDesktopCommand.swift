import ArgumentParser

struct SwitchDesktopCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "switch-desktop",
    abstract: "Switch to a specific desktop (1-9)"
  )

  @Argument(help: "Desktop number (1-9)")
  var desktopNumber: Int

  func run() throws {
    try Permissions.checkAccessibility()
    try WindowManager.main.switchToDesktop(number: desktopNumber)
  }
}
