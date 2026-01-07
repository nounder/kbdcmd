import ArgumentParser
import Foundation

struct ShortcutCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "shortcut",
    abstract: "Run a macOS Shortcut by name"
  )

  @Argument(help: "Name of the shortcut to run")
  var name: String

  @Option(name: .shortAndLong, help: "Input file path to pass to the shortcut")
  var input: String?

  @Option(name: .shortAndLong, help: "Output file path to write the result")
  var output: String?

  func run() throws {
    var arguments = ["run", name]

    if let inputPath = input {
      arguments += ["-i", inputPath]
    }

    if let outputPath = output {
      arguments += ["-o", outputPath]
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
    process.arguments = arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

    if let outputString = String(data: outputData, encoding: .utf8), !outputString.isEmpty {
      print(outputString, terminator: "")
    }

    if process.terminationStatus != 0 {
      if let errorString = String(data: errorData, encoding: .utf8), !errorString.isEmpty {
        throw ValidationError("Shortcut failed: \(errorString)")
      } else {
        throw ValidationError("Shortcut '\(name)' failed with exit code \(process.terminationStatus)")
      }
    }
  }
}
