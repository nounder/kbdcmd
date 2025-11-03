import ArgumentParser

struct MarkWindowCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mark-window",
    abstract: "Mark the current window with a character for quick access"
  )

  func run() throws {
    try Permissions.checkAccessibility()
    WindowMarkManager.shared.markWindow()
  }
}
