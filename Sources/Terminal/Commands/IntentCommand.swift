import ArgumentParser
import Foundation

struct IntentCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "intent",
    abstract: "Run an App Intent via Shortcuts",
    discussion: """
      Runs App Intents exposed by applications through the Shortcuts system.

      Apple does not provide a public API for direct cross-app intent invocation.
      This command runs a Shortcut that wraps the desired intent.

      Examples:
        kbdcmd intent "Create Note"
        kbdcmd intent "Send Message" --input "Hello World"
      """
  )

  @Argument(help: "Name of the shortcut that wraps the intent")
  var shortcutName: String

  @Option(name: .shortAndLong, help: "Input to pass to the intent")
  var input: String?

  func run() async throws {
    var arguments = ["run", shortcutName]

    if input != nil {
      // Pass input via stdin
      arguments += ["--input-path", "-"]
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
    process.arguments = arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    if let inputValue = input {
      let inputPipe = Pipe()
      process.standardInput = inputPipe
      try process.run()
      try? inputPipe.fileHandleForWriting.write(contentsOf: Data(inputValue.utf8))
      try? inputPipe.fileHandleForWriting.close()
    } else {
      try process.run()
    }

    process.waitUntilExit()

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

    if let outputString = String(data: outputData, encoding: .utf8), !outputString.isEmpty {
      print(outputString, terminator: "")
    }

    if process.terminationStatus != 0 {
      if let errorString = String(data: errorData, encoding: .utf8), !errorString.isEmpty {
        throw ValidationError("Intent failed: \(errorString)")
      } else {
        throw ValidationError("Shortcut '\(shortcutName)' failed with exit code \(process.terminationStatus)")
      }
    }
  }
}
