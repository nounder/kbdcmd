import AppKit
import ArgumentParser
import Core
import Foundation

struct OsaCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "osa",
    abstract: "Run JavaScript for Automation (JXA) via Open Scripting Architecture",
    discussion: """
      Executes JXA commands on applications or runs JXA code from stdin.

      Examples:
        kbdcmd osa Spotify                          # List available commands/properties
        kbdcmd osa Spotify playerstate              # Get a property
        kbdcmd osa Spotify playpause                # Call a command
        kbdcmd osa Spotify play spotify:track:123   # Call with argument
        echo 'Application("Finder").name()' | kbdcmd osa   # Run JXA from stdin
      """
  )

  @Argument(help: "Application name")
  var app: String?

  @Argument(help: "Command or property name")
  var command: String?

  @Argument(parsing: .remaining, help: "Arguments to pass to the command")
  var args: [String] = []

  @Flag(name: .long, help: "Show only commands")
  var commands = false

  @Flag(name: .long, help: "Show only classes")
  var classes = false

  @Flag(name: .long, help: "Show only properties")
  var properties = false

  @Option(name: .shortAndLong, parsing: .upToNextOption, help: "Properties to extract from result objects")
  var prop: [String] = []

  func run() throws {
    // If no app provided, read from stdin
    guard let appName = app else {
      let inputData = FileHandle.standardInput.readDataToEndOfFile()
      guard let inputCode = String(data: inputData, encoding: .utf8),
            !inputCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ValidationError("No application specified and no JXA code provided via stdin.")
      }
      let wrappedCode = wrapWithExtraction(inputCode.trimmingCharacters(in: .whitespacesAndNewlines), propsToExtract: [])
      try executeJxa(wrappedCode)
      return
    }

    // If no command provided, list available commands/properties
    guard let methodName = command else {
      try listCommands(for: appName)
      return
    }

    // Load SDEF for the app to get type information
    let sdef = try loadSdef(for: appName)

    // Execute the command/property
    let propsToExtract = prop.flatMap { $0.split(separator: ",").map(String.init) }
    let code = buildJxaCode(app: appName, method: methodName, params: args, sdef: sdef, extractProps: propsToExtract)
    try executeJxa(code)
  }

  private func loadSdef(for appName: String) throws -> Sdef? {
    let appPath = try resolveAppPath(appName)
    let appURL = URL(fileURLWithPath: appPath)
    let resourcesURL = appURL.appendingPathComponent("Contents/Resources")

    let fileManager = FileManager.default
    guard let contents = try? fileManager.contentsOfDirectory(at: resourcesURL, includingPropertiesForKeys: nil),
          let sdefURL = contents.first(where: { $0.pathExtension == "sdef" }),
          let xmlString = try? String(contentsOf: sdefURL, encoding: .utf8) else {
      return nil
    }

    return parseSdef(from: xmlString)
  }

  private func resolveAppPath(_ appName: String) throws -> String {
    let fileManager = FileManager.default

    // Check if it's a path
    let isPath = appName.contains("/") || appName.hasPrefix(".")
    if isPath {
      let fullPath = appName.hasPrefix("/")
        ? appName
        : (fileManager.currentDirectoryPath as NSString).appendingPathComponent(appName)
      if fileManager.fileExists(atPath: fullPath) {
        return fullPath
      }
      throw ValidationError("No application at \(appName)")
    }

    // Check cwd first
    let cwdPath = (fileManager.currentDirectoryPath as NSString).appendingPathComponent(
      appName.hasSuffix(".app") ? appName : "\(appName).app")
    if fileManager.fileExists(atPath: cwdPath) {
      return cwdPath
    }

    // Use ApplicationManager to resolve standard locations
    if let path = ApplicationManager.resolve(appName) {
      return path
    }

    // Use NSWorkspace to find app by bundle identifier (handles Finder in CoreServices, etc.)
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.\(appName)") {
      return url.path
    }

    // Search in additional system locations
    let normalizedName = appName.hasSuffix(".app") ? appName : "\(appName).app"
    let additionalPaths = [
      "/System/Library/CoreServices",
      "/System/Library/CoreServices/Applications",
    ]
    for searchPath in additionalPaths {
      let appPath = (searchPath as NSString).appendingPathComponent(normalizedName)
      if fileManager.fileExists(atPath: appPath) {
        return appPath
      }
    }

    throw ValidationError("Could not find application '\(appName)'")
  }

  private func listCommands(for appName: String) throws {
    let appPath = try resolveAppPath(appName)

    // Find .sdef file in app bundle Resources
    let appURL = URL(fileURLWithPath: appPath)
    let resourcesURL = appURL.appendingPathComponent("Contents/Resources")

    let fileManager = FileManager.default
    guard let contents = try? fileManager.contentsOfDirectory(at: resourcesURL, includingPropertiesForKeys: nil) else {
      throw ValidationError("Application '\(appName)' does not have a scripting dictionary")
    }

    guard let sdefURL = contents.first(where: { $0.pathExtension == "sdef" }) else {
      throw ValidationError("Application '\(appName)' does not have a scripting dictionary")
    }

    guard let xmlString = try? String(contentsOf: sdefURL, encoding: .utf8) else {
      throw ValidationError("Failed to read sdef file")
    }

    let sdef = parseSdef(from: xmlString)
    let showAll = !commands && !classes && !properties

    // Output as JSON
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    if showAll {
      if let jsonData = try? encoder.encode(sdef),
         let jsonString = String(data: jsonData, encoding: .utf8) {
        print(jsonString)
      }
    } else {
      let filtered = FilteredSdef(
        commands: commands ? sdef.commands : nil,
        classes: classes ? sdef.classes : nil,
        properties: properties ? sdef.properties : nil
      )
      if let jsonData = try? encoder.encode(filtered),
         let jsonString = String(data: jsonData, encoding: .utf8) {
        print(jsonString)
      }
    }
  }

  private struct FilteredSdef: Encodable {
    let commands: [String: Sdef.Command]?
    let classes: [String: Sdef.Class]?
    let properties: [String: Sdef.Property]?

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      if let commands = commands {
        try container.encode(commands, forKey: .commands)
      }
      if let classes = classes {
        try container.encode(classes, forKey: .classes)
      }
      if let properties = properties {
        try container.encode(properties, forKey: .properties)
      }
    }

    enum CodingKeys: String, CodingKey {
      case commands, classes, properties
    }
  }

  fileprivate struct Sdef: Encodable {
    let commands: [String: Command]
    let properties: [String: Property]
    let classes: [String: Class]

    struct Command: Encodable {
      let parameters: [String: Parameter]
      let result: String?

      struct Parameter: Encodable {
        let optional: Bool
      }
    }

    struct Property: Encodable {
      let access: String
      let type: String?
    }

    struct Class: Encodable {
      let properties: [String]
    }
  }

  private func parseSdef(from xml: String) -> Sdef {
    let parser = SdefParser()
    return parser.parse(xml)
  }

  private func buildJxaCode(app: String, method: String, params: [String], sdef: Sdef?, extractProps userProps: [String]) -> String {
    let escapedApp = escapeJsString(app)

    // Parse params: positional args and named args (key=value)
    // Prefix with $ to pass raw JXA expression (e.g., $app.playlists[0])
    var positionalArgs: [String] = []
    var namedArgs: [(String, String, Bool)] = []  // (key, value, isRaw)

    for param in params {
      if let eqIdx = param.firstIndex(of: "="), eqIdx != param.startIndex {
        let key = String(param[..<eqIdx])
        let value = String(param[param.index(after: eqIdx)...])
        let isRaw = value.hasPrefix("$")
        namedArgs.append((key, isRaw ? String(value.dropFirst()) : value, isRaw))
      } else if param.hasPrefix("$") {
        // Raw expression as positional arg
        positionalArgs.append(String(param.dropFirst()))
      } else {
        positionalArgs.append("\"\(escapeJsString(param))\"")
      }
    }

    // Build the call
    let appVar = "Application(\"\(escapedApp)\")"
    var callArgs: [String] = positionalArgs
    if !namedArgs.isEmpty {
      let namedObj = namedArgs.map { arg in
        let (key, value, isRaw) = arg
        return isRaw ? "\(key): \(value)" : "\(key): \"\(escapeJsString(value))\""
      }.joined(separator: ", ")
      callArgs.append("{\(namedObj)}")
    }
    let call = callArgs.isEmpty ? "\(appVar).\(method)" : "\(appVar).\(method)(\(callArgs.joined(separator: ", ")))"

    // Determine properties to extract
    var propsToExtract: [String] = userProps
    if propsToExtract.isEmpty, let sdef = sdef {
      // Look up the return type from SDEF
      var returnType: String?
      if let prop = sdef.properties[method] {
        returnType = prop.type
      } else if let cmd = sdef.commands[method] {
        returnType = cmd.result
      }
      if let typeName = returnType, let classInfo = sdef.classes[typeName] {
        propsToExtract = classInfo.properties
      }
    }

    return wrapWithExtraction("(function(){ var app = \(appVar); return \(call); })()", propsToExtract: propsToExtract)
  }

  private func wrapWithExtraction(_ expression: String, propsToExtract: [String]) -> String {
    let propsJs = propsToExtract.isEmpty
      ? "Object.keys(o.properties ? o.properties() : {})"
      : "[\(propsToExtract.map { "\"\($0)\"" }.joined(separator: ", "))]"
    return """
      (function() {
        var obj = \(expression);
        if (typeof obj === 'function') obj = obj();
        function extractProps(o) {
          if (typeof o !== 'function') return o;
          var props = \(propsJs);
          var result = {"[display]": Automation.getDisplayString(o)};
          for (var i = 0; i < props.length; i++) {
            var p = props[i];
            try { result[p] = o[p](); } catch(e) {}
          }
          return result;
        }
        if (typeof obj !== 'object' || obj === null) return obj;
        if (Array.isArray(obj)) {
          var arr = [];
          for (var i = 0; i < obj.length; i++) arr.push(extractProps(obj[i]));
          return JSON.stringify(arr, null, 2);
        }
        return JSON.stringify(extractProps(obj), null, 2);
      })()
      """
  }

  private func toCamelCase(_ str: String) -> String {
    let words = str.split(separator: " ")
    guard let first = words.first else { return str }
    let rest = words.dropFirst().map { $0.capitalized }
    return String(first).lowercased() + rest.joined()
  }

  private func escapeJsString(_ str: String) -> String {
    str
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\t", with: "\\t")
  }

  private func executeJxa(_ code: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-l", "JavaScript", "-e", code]

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
        throw ValidationError("JXA execution failed: \(errorString)")
      } else {
        throw ValidationError("JXA execution failed with exit code \(process.terminationStatus)")
      }
    }
  }
}

private class SdefParser: NSObject, XMLParserDelegate {
  private var commands: [String: OsaCommand.Sdef.Command] = [:]
  private var properties: [String: OsaCommand.Sdef.Property] = [:]
  private var classes: [String: OsaCommand.Sdef.Class] = [:]

  private var currentClassName: String?
  private var currentClassProps: [String] = []
  private var currentCommandName: String?
  private var currentCommandParams: [String: OsaCommand.Sdef.Command.Parameter] = [:]
  private var currentCommandResult: String?

  func parse(_ xml: String) -> OsaCommand.Sdef {
    guard let data = xml.data(using: .utf8) else {
      return OsaCommand.Sdef(commands: [:], properties: [:], classes: [:])
    }
    let parser = XMLParser(data: data)
    parser.delegate = self
    parser.parse()
    return OsaCommand.Sdef(commands: commands, properties: properties, classes: classes)
  }

  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
              qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
    switch elementName {
    case "class":
      if let name = attributeDict["name"] {
        currentClassName = name
        currentClassProps = []
      }

    case "command":
      if let name = attributeDict["name"] {
        currentCommandName = toCamelCase(name)
        currentCommandParams = [:]
        currentCommandResult = nil
      }

    case "property":
      guard let name = attributeDict["name"] else { return }
      let camelName = toCamelCase(name)

      if currentClassName != nil {
        currentClassProps.append(camelName)
      }

      if currentClassName == "application" {
        let access = attributeDict["access"] == "r" ? "r" : "rw"
        let type = attributeDict["type"]
        properties[camelName] = OsaCommand.Sdef.Property(access: access, type: type)
      }

    case "direct-parameter":
      if let name = attributeDict["name"] {
        let camelName = toCamelCase(name)
        let optional = attributeDict["optional"] == "yes"
        currentCommandParams[camelName] = OsaCommand.Sdef.Command.Parameter(optional: optional)
      } else {
        let optional = attributeDict["optional"] == "yes"
        currentCommandParams["_"] = OsaCommand.Sdef.Command.Parameter(optional: optional)
      }

    case "parameter":
      if let name = attributeDict["name"] {
        let camelName = toCamelCase(name)
        let optional = attributeDict["optional"] == "yes"
        currentCommandParams[camelName] = OsaCommand.Sdef.Command.Parameter(optional: optional)
      }

    case "result":
      currentCommandResult = attributeDict["type"]

    default:
      break
    }
  }

  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
              qualifiedName qName: String?) {
    switch elementName {
    case "class":
      if let name = currentClassName {
        classes[name] = OsaCommand.Sdef.Class(properties: currentClassProps)
      }
      currentClassName = nil

    case "command":
      if let name = currentCommandName {
        commands[name] = OsaCommand.Sdef.Command(
          parameters: currentCommandParams,
          result: currentCommandResult
        )
      }
      currentCommandName = nil

    default:
      break
    }
  }

  private func toCamelCase(_ str: String) -> String {
    let words = str.split(separator: " ")
    guard let first = words.first else { return str }
    let rest = words.dropFirst().map { $0.capitalized }
    return String(first).lowercased() + rest.joined()
  }
}
