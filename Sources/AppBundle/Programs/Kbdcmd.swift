import ArgumentParser
import Foundation

@main
struct Kbdcmd: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "kbdcmd",
    abstract: "Keyboard Command for macOS",
    version: "0.2.0",
    subcommands: [
      DaemonCommand.self,
      OpenCommand.self,
      CycleCommand.self,
      OpenCycleCommand.self,
      SwitchDesktopCommand.self,
      MarkWindowCommand.self,
      FocusMarkCommand.self,
    ]
  )
}
