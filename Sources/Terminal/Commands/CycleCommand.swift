import ArgumentParser
import Core

@available(macOS 15.0, *)
struct CycleCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "cycle",
    abstract: "Cycle through windows of the frontmost application"
  )

  func run() async throws {
    try Permissions.checkAccessibility()
    await WindowManager.main.cycleAppWindows()
  }
}
