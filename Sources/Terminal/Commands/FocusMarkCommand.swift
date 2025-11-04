import ArgumentParser
import Core

struct FocusMarkCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "focus-mark",
    abstract: "Focus a window by its mark character"
  )

  @Argument(help: "Mark character to focus")
  var mark: String

  func run() throws {
    try Permissions.checkAccessibility()
    WindowMarkManager.shared.focusMarkedWindow(mark: mark)
  }
}
