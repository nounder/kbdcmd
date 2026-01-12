import ArgumentParser
import Foundation

struct ClickCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "click",
    abstract: "Perform mouse click (alias for 'perform click')"
  )

  @Argument(parsing: .remaining, help: "Coordinates (@x,y or @x,y,w,h)")
  var operands: [String] = []

  @Option(name: .shortAndLong, help: "Target specific app by name or bundle ID")
  var app: String?

  @Option(name: .long, help: "Target specific window by title")
  var title: String?

  @Option(name: .long, help: "Target specific app by process ID")
  var pid: pid_t?

  @Option(name: .long, help: "Target specific window by CGWindowID")
  var cgid: Int?

  @Flag(name: .long, help: "Print debug information")
  var debug: Bool = false

  @Flag(name: .long, help: "Run tree command after action completes")
  var walk: Bool = false

  @Flag(name: .long, help: "Perform double-click")
  var double: Bool = false

  @MainActor
  func run() async throws {
    var args = ["click"] + operands
    if let app = app { args += ["--app", app] }
    if let title = title { args += ["--title", title] }
    if let pid = pid { args += ["--pid", String(pid)] }
    if let cgid = cgid { args += ["--cgid", String(cgid)] }
    if debug { args += ["--debug"] }
    if walk { args += ["--walk"] }
    if double { args += ["--double"] }
    let cmd = try PerformCommand.parse(args)
    try await cmd.run()
  }
}

struct TypeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "type",
    abstract: "Type text at current focus (alias for 'perform type')"
  )

  @Argument(parsing: .remaining, help: "Text and/or chords to type (e.g., \"hello\" \"<cmd-a>\" \"<0.5>\")")
  var operands: [String] = []

  @Option(name: .long, help: "Delay between keystrokes in seconds")
  var delay: Double = 0.05

  @Option(name: .long, help: "Wait time in seconds before starting")
  var wait: Double = 0

  @Flag(name: .long, help: "Clear input field before typing (select all + delete)")
  var clear: Bool = false

  @MainActor
  func run() async throws {
    var args = ["type"] + operands
    args += ["--delay", String(delay)]
    args += ["--wait", String(wait)]
    if clear {
      args += ["--clear"]
    }
    let cmd = try PerformCommand.parse(args)
    try await cmd.run()
  }
}
