import ArgumentParser
import Core
import Foundation

@main
struct Kbdcmd: AsyncParsableCommand {
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
      SnapshotCommand.self,
      WalkerCommand.self,
      KeyboardCommand.self,
      IntentCommand.self,
      ShortcutCommand.self,
      WindowListCommand.self,
      PerformCommand.self,
      HelpWorkflowsCommand.self,
    ]
  )
}
