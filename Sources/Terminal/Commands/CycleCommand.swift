import ArgumentParser
import Core

struct CycleCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "cycle",
    abstract: "Cycle through windows of the frontmost application"
  )

  func run() throws {
    try Permissions.checkAccessibility()
    WindowManager.main.cycleAppWindows()
  }
}
