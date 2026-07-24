import AppKit
import ArgumentParser
import Core
import Foundation

struct DaemonCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "daemon",
    abstract: "Start the keyboard command daemon"
  )

  func run() throws {
    try Permissions.checkAccessibility()

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    print("kbdcmd daemon started")
    DaemonRuntime.start()
    app.run()
  }
}
