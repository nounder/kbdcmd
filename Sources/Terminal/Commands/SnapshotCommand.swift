import AppKit
import ApplicationServices
import ArgumentParser
import Core
import Foundation

struct SnapshotCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "snapshot",
    abstract: "Capture and print an accessibility tree snapshot",
    discussion: """
      Common attributes to filter:
        Basic: AXRole, AXSubrole, AXTitle, AXDescription, AXIdentifier
        State: AXEnabled, AXFocused, AXSelected, AXMain, AXMinimized
        Geometry: AXPosition, AXSize, AXFrame
        Value: AXValue, AXMinValue, AXMaxValue
        Window: AXMain, AXModal, AXDocument
        Text: AXSelectedText, AXNumberOfCharacters
        Navigation: AXParent, AXChildren, AXURL

      Use --full to include all ~110 standard attributes in output.
      See ATTRIBUTE_COLLECTION.md for complete attribute list.
      """
  )

  @Option(name: .shortAndLong, help: "Output format (text or json)")
  var format: OutputFormat = .text

  @Option(
    name: .shortAndLong, help: "Filter attributes (comma-separated list, e.g., 'AXRole,AXTitle')")
  var attributes: String?

  @Flag(name: .long, help: "Include all ~110 standard attributes in output")
  var full: Bool = false

  @Flag(name: .shortAndLong, help: "Include timing information")
  var timing: Bool = false

  @Flag(name: .long, help: "Traverse all windows (default: only frontmost window)")
  var allWindows: Bool = false

  @Flag(name: .long, help: "Interactively pick a window to snapshot")
  var pickWindow: Bool = false

  enum OutputFormat: String, ExpressibleByArgument {
    case text
    case json
  }

  func run() throws {
    try Permissions.checkAccessibility()

    // If --pick-window is set, show interactive picker
    if pickWindow {
      try pickAndSnapshotWindow()
      return
    }

    // Get frontmost application
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
      throw ValidationError("No frontmost application")
    }

    let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)

    // Determine root element: use focused window by default, or app element if --all-windows
    let rootElement: AXUIElement
    let scopeDescription: String

    if allWindows {
      rootElement = appElement
      scopeDescription = "all windows"
    } else {
      // Get the focused window using Accessibility API directly
      var focusedWindowValue: AnyObject?
      let result = AXUIElementCopyAttributeValue(
        appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue)

      guard result == .success,
        let windowValue = focusedWindowValue,
        CFGetTypeID(windowValue as CFTypeRef) == AXUIElementGetTypeID()
      else {
        throw ValidationError("No focused window found")
      }
      rootElement = (windowValue as! AXUIElement)
      scopeDescription = "frontmost window"
    }

    performSnapshot(rootElement: rootElement, scopeDescription: scopeDescription)
  }

  private func pickAndSnapshotWindow() throws {
    // Ensure we're on the main thread for UI operations
    guard Thread.isMainThread else {
      // Capture and propagate errors from the main thread dispatch
      // Using try? would silently swallow errors, violating the throws contract
      var capturedError: Error?
      DispatchQueue.main.sync {
        do {
          try pickAndSnapshotWindow()
        } catch {
          capturedError = error
        }
      }
      if let error = capturedError {
        throw error
      }
      return
    }

    // Create an application instance for the run loop
    let app = NSApplication.shared

    var selectedWindowInfo: PickerWindowInfo?

    let picker = WindowPicker()
    picker.pickWindow { windowInfo in
      selectedWindowInfo = windowInfo
      app.stop(nil)
    }

    // Run the application event loop until picker completes
    app.run()

    guard let windowInfo = selectedWindowInfo else {
      throw ValidationError("No window selected")
    }

    let rootElement: AXUIElement
    if let axElement = windowInfo.axElement {
      rootElement = axElement
    } else if let fallback = WindowPicker.getAXWindow(from: windowInfo) {
      rootElement = fallback
    } else {
      throw ValidationError("Could not access the selected window")
    }

    let appName = windowInfo.appName ?? "Unknown"
    let windowTitle = windowInfo.title ?? "Untitled"
    let scopeDescription = "\(appName) - \(windowTitle)"

    performSnapshot(rootElement: rootElement, scopeDescription: scopeDescription)
  }

  private func performSnapshot(rootElement: AXUIElement, scopeDescription: String) {
    // Parse attribute filter
    let attributeFilter = parseAttributeFilter()

    print("=== Accessibility Tree Snapshot ===")
    print("Scope: \(scopeDescription)")
    print("Timestamp: \(formatDate(Date()))")
    print()

    // For text output, show nodes as they're captured in real-time
    if format == .text {
      print("=== Tree Structure ===")
    }

    let startTime = Date()
    var nodeCount = 0

    // For JSON mode, print opening bracket for array
    if format == .json {
      print("[")
    }

    var isFirstJsonNode = true

    let _ = AXSnapshot.snapshot(root: rootElement) { nodeId, count, node in
      nodeCount = count

      if format == .text {
        // Print node in real-time for text mode with full details
        let depth = nodeId.components(separatedBy: "-").count - 1
        let prefix = String(repeating: "  ", count: depth)
        let role = extractStringValue(node.attributes["AXRole"]) ?? "Unknown"
        let title = extractStringValue(node.attributes["AXTitle"])

        // Print node header
        print("\(prefix)[\(nodeId)] \(role)", terminator: "")
        if let title = title, !title.isEmpty {
          print(" - \"\(title)\"")
        } else {
          print()
        }

        // Print geometry if available
        if let bounds = node.bounds {
          print(
            "\(prefix)  @ (\(Int(bounds.origin.x)), \(Int(bounds.origin.y))) \(Int(bounds.width))×\(Int(bounds.height))",
            terminator: "")
          if let z = node.zIndex {
            print(" z:\(z)")
          } else {
            print()
          }
        }

        // Print attributes if --full or --attributes is specified
        if let filter = attributeFilter {
          let filteredAttrs = node.attributes.filter { filter.contains($0.key) }
          if !filteredAttrs.isEmpty {
            print("\(prefix)  Attributes:")
            for (key, value) in filteredAttrs.sorted(by: { $0.key < $1.key }) {
              print("\(prefix)    \(key): \(formatValue(value))")
            }
          }
        } else if full {
          if !node.attributes.isEmpty {
            print("\(prefix)  Attributes:")
            for (key, value) in node.attributes.sorted(by: { $0.key < $1.key }) {
              print("\(prefix)    \(key): \(formatValue(value))")
            }
          }
        }

        // Print actions if any
        if !node.actions.isEmpty {
          let actionNames = node.actions.map { $0.name }.joined(separator: ", ")
          print("\(prefix)  Actions: \(actionNames)")
        }

        // Print parameterized attributes if any
        if !node.parameterizedAttributes.isEmpty {
          let paramNames = node.parameterizedAttributes.joined(separator: ", ")
          print("\(prefix)  Parameterized: \(paramNames)")
        }

        fflush(stdout)
      } else {
        // JSON mode: print each node as flat object in array
        // Add comma before each node except the first
        if !isFirstJsonNode {
          print(",")
        }
        isFirstJsonNode = false

        // Print node as JSON object
        try? printFlatJsonNode(node, attributeFilter: attributeFilter)
        fflush(stdout)
      }
    }

    let duration = Date().timeIntervalSince(startTime)

    // Finalize output based on format
    if format == .text {
      print()
      print("Captured \(nodeCount) nodes in \(String(format: "%.3f", duration))s")
    } else {
      // Close JSON array
      print()
      print("]")
    }
  }

  private func parseAttributeFilter() -> Set<String>? {
    // If --full flag is set, return nil to include all attributes
    if full {
      return nil
    }

    guard let attributes = attributes else {
      return nil
    }

    let filtered =
      attributes
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }

    return filtered.isEmpty ? nil : Set(filtered)
  }

  private func printTextOutput(snapshot: AXSnapshot, attributeFilter: Set<String>?) {
    print("=== Accessibility Tree Snapshot ===")
    print("Application: \(getAppName(snapshot.root))")
    print("Timestamp: \(formatDate(snapshot.metadata.timestamp))")
    print("Node Count: \(snapshot.metadata.nodeCount)")
    print("Duration: \(formatDuration(snapshot.metadata.totalDuration))")
    print()

    print("=== Tree Structure ===")

    // Build timing lookup map if timing is enabled
    let timingMap = timing ? buildTimingMap(snapshot.timings) : nil

    printNode(snapshot.root, indent: 0, attributeFilter: attributeFilter, timingMap: timingMap)
  }

  private func printNode(
    _ node: AXSnapshotNode,
    indent: Int,
    attributeFilter: Set<String>?,
    timingMap: [String: NodeTiming]?
  ) {
    let prefix = String(repeating: "  ", count: indent)
    let role = extractStringValue(node.attributes["AXRole"]) ?? "Unknown"
    let title = extractStringValue(node.attributes["AXTitle"])

    // Print node header
    print("\(prefix)[\(node.id)] \(role)", terminator: "")
    if let title = title, !title.isEmpty {
      print(" - \"\(title)\"", terminator: "")
    }
    print()

    // Print geometry if available
    if let bounds = node.bounds {
      print(
        "\(prefix)  @ (\(Int(bounds.origin.x)), \(Int(bounds.origin.y))) \(Int(bounds.width))×\(Int(bounds.height))",
        terminator: "")
      if let z = node.zIndex {
        print(" z:\(z)", terminator: "")
      }
      print()
    }

    // Print timing information for this node if available (right after geometry)
    if let timing = timingMap?[node.id] {
      print(
        "\(prefix)  ⏱ attributes: \(String(format: "%.2f", timing.attributes * 1000))ms, "
          + "actions: \(String(format: "%.2f", timing.actions * 1000))ms, "
          + "geometry: \(String(format: "%.2f", timing.geometry * 1000))ms, "
          + "total: \(String(format: "%.2f", timing.total * 1000))ms"
      )
    }

    // Print attributes (all if --full, filtered if --attributes specified)
    // Only show if explicitly requested
    if let filter = attributeFilter {
      let filteredAttrs = node.attributes.filter { filter.contains($0.key) }
      if !filteredAttrs.isEmpty {
        print("\(prefix)  Attributes:")
        for (key, value) in filteredAttrs.sorted(by: { $0.key < $1.key }) {
          print("\(prefix)    \(key): \(formatValue(value))")
        }
      }
    } else if full {
      // Print all attributes when --full is specified
      if !node.attributes.isEmpty {
        print("\(prefix)  Attributes:")
        for (key, value) in node.attributes.sorted(by: { $0.key < $1.key }) {
          print("\(prefix)    \(key): \(formatValue(value))")
        }
      }
    }

    // Print actions if any
    if !node.actions.isEmpty {
      let actionNames = node.actions.map { $0.name }.joined(separator: ", ")
      print("\(prefix)  Actions: \(actionNames)")
    }

    // Print parameterized attributes if any
    if !node.parameterizedAttributes.isEmpty {
      let paramNames = node.parameterizedAttributes.joined(separator: ", ")
      print("\(prefix)  Parameterized: \(paramNames)")
    }

    // Recursively print children
    for child in node.children {
      printNode(child, indent: indent + 1, attributeFilter: attributeFilter, timingMap: timingMap)
    }
  }

  private func printTimingStats(_ timings: [TimingEntry]) {
    print("=== Timing Statistics ===")

    // Group by operation
    let byOperation = Dictionary(grouping: timings) { $0.operation }

    for (operation, entries) in byOperation.sorted(by: { $0.key < $1.key }) {
      let total = entries.map(\.duration).reduce(0, +)
      let avg = total / Double(entries.count)
      let max = entries.map(\.duration).max() ?? 0

      print(
        String(
          format: "%@: total=%.3fs avg=%.3fms max=%.3fms count=%d",
          operation,
          total,
          avg * 1000,
          max * 1000,
          entries.count
        ))
    }
  }

  private struct NodeTiming {
    let attributes: TimeInterval
    let actions: TimeInterval
    let geometry: TimeInterval
    let parameterized: TimeInterval

    var total: TimeInterval {
      attributes + actions + geometry + parameterized
    }
  }

  private func buildTimingMap(_ timings: [TimingEntry]) -> [String: NodeTiming] {
    var map: [String: NodeTiming] = [:]

    // Group by node ID
    let byNode = Dictionary(grouping: timings) { $0.nodeId }

    for (nodeId, entries) in byNode {
      var attributes: TimeInterval = 0
      var actions: TimeInterval = 0
      var geometry: TimeInterval = 0
      var parameterized: TimeInterval = 0

      for entry in entries {
        switch entry.operation {
        case "attributes":
          attributes = entry.duration
        case "actions":
          actions = entry.duration
        case "geometry":
          geometry = entry.duration
        case "parameterized":
          parameterized = entry.duration
        default:
          break
        }
      }

      map[nodeId] = NodeTiming(
        attributes: attributes,
        actions: actions,
        geometry: geometry,
        parameterized: parameterized
      )
    }

    return map
  }

  private func printJsonOutput(snapshot: AXSnapshot, attributeFilter: Set<String>?) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    // If timing is enabled, create enriched output with timing data
    if timing {
      let timingMap = buildTimingMap(snapshot.timings)
      let enrichedOutput = createEnrichedOutput(
        snapshot: snapshot, timingMap: timingMap, attributeFilter: attributeFilter)
      let jsonData = try encoder.encode(enrichedOutput)
      if let jsonString = String(data: jsonData, encoding: .utf8) {
        print(jsonString)
      }
    } else {
      // Standard output without timing
      let outputSnapshot: AXSnapshot
      if let filter = attributeFilter {
        outputSnapshot = filterSnapshot(snapshot, attributes: filter)
      } else {
        outputSnapshot = snapshot
      }

      let jsonData = try encoder.encode(outputSnapshot)
      if let jsonString = String(data: jsonData, encoding: .utf8) {
        print(jsonString)
      }
    }
  }

  private func filterSnapshot(_ snapshot: AXSnapshot, attributes: Set<String>) -> AXSnapshot {
    // Create a new snapshot with filtered attributes
    let filteredRoot = filterNode(snapshot.root, attributes: attributes)

    return AXSnapshot(
      root: filteredRoot,
      timings: timing ? snapshot.timings : [],
      metadata: snapshot.metadata
    )
  }

  private func filterNode(_ node: AXSnapshotNode, attributes: Set<String>) -> AXSnapshotNode {
    let filteredAttributes = node.attributes.filter { attributes.contains($0.key) }

    let newNode = AXSnapshotNode(
      id: node.id,
      parent: nil,  // Will be set when building tree
      prevSibling: nil,
      nextSibling: nil,
      children: [],
      attributes: filteredAttributes,
      parameterizedAttributes: node.parameterizedAttributes,
      actions: node.actions,
      bounds: node.bounds,
      zIndex: node.zIndex
    )

    // Recursively filter children
    newNode.children = node.children.map { child in
      let filteredChild = filterNode(child, attributes: attributes)
      filteredChild.parent = newNode
      return filteredChild
    }

    // Wire up sibling relationships
    for i in 0..<newNode.children.count {
      if i > 0 {
        newNode.children[i].prevSibling = newNode.children[i - 1]
      }
      if i < newNode.children.count - 1 {
        newNode.children[i].nextSibling = newNode.children[i + 1]
      }
    }

    return newNode
  }

  // MARK: - Enriched JSON Output with Timing

  private struct EnrichedSnapshot: Codable {
    let root: EnrichedNode
    let metadata: AXSnapshot.SnapshotMetadata
  }

  private struct JsonReference: Codable {
    let ref: String

    enum CodingKeys: String, CodingKey {
      case ref = "@id"
    }
  }

  private struct EnrichedNode: Codable {
    let id: String
    let parent: JsonReference?
    let prevSibling: JsonReference?
    let nextSibling: JsonReference?
    let children: [EnrichedNode]

    let attributes: [String: AXSnapshotValue]
    let parameterizedAttributes: [String]
    let actions: [AXSnapshotAction]

    let bounds: CGRect?
    let zIndex: Int?

    let timing: TimingInfo?

    struct TimingInfo: Codable {
      let attributes: Double  // in milliseconds
      let actions: Double
      let geometry: Double
      let parameterized: Double
      let total: Double
    }

    enum CodingKeys: String, CodingKey {
      case id = "@id"
      case parent, prevSibling, nextSibling, children
      case attributes, parameterizedAttributes, actions
      case bounds, zIndex, timing
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(id, forKey: .id)
      try container.encodeIfPresent(parent, forKey: .parent)
      try container.encodeIfPresent(prevSibling, forKey: .prevSibling)
      try container.encodeIfPresent(nextSibling, forKey: .nextSibling)
      try container.encode(children, forKey: .children)
      try container.encode(attributes, forKey: .attributes)
      try container.encode(parameterizedAttributes, forKey: .parameterizedAttributes)
      try container.encode(actions, forKey: .actions)

      // Encode bounds as nested object
      if let bounds = bounds {
        var boundsDict: [String: Double] = [:]
        boundsDict["x"] = bounds.origin.x
        boundsDict["y"] = bounds.origin.y
        boundsDict["width"] = bounds.width
        boundsDict["height"] = bounds.height
        try container.encode(boundsDict, forKey: .bounds)
      }

      try container.encodeIfPresent(zIndex, forKey: .zIndex)
      try container.encodeIfPresent(timing, forKey: .timing)
    }
  }

  private func createEnrichedOutput(
    snapshot: AXSnapshot,
    timingMap: [String: NodeTiming],
    attributeFilter: Set<String>?
  ) -> EnrichedSnapshot {
    let enrichedRoot = enrichNode(
      snapshot.root, timingMap: timingMap, attributeFilter: attributeFilter)
    return EnrichedSnapshot(root: enrichedRoot, metadata: snapshot.metadata)
  }

  private func enrichNode(
    _ node: AXSnapshotNode,
    timingMap: [String: NodeTiming],
    attributeFilter: Set<String>?
  ) -> EnrichedNode {
    // Filter attributes if needed
    let attrs: [String: AXSnapshotValue]
    if let filter = attributeFilter {
      attrs = node.attributes.filter { filter.contains($0.key) }
    } else {
      attrs = node.attributes
    }

    // Get timing info
    let timingInfo: EnrichedNode.TimingInfo?
    if let timing = timingMap[node.id] {
      timingInfo = EnrichedNode.TimingInfo(
        attributes: timing.attributes * 1000,  // Convert to ms
        actions: timing.actions * 1000,
        geometry: timing.geometry * 1000,
        parameterized: timing.parameterized * 1000,
        total: timing.total * 1000
      )
    } else {
      timingInfo = nil
    }

    // Enrich children
    let enrichedChildren = node.children.map { child in
      enrichNode(child, timingMap: timingMap, attributeFilter: attributeFilter)
    }

    return EnrichedNode(
      id: node.id,
      parent: node.parent.map { JsonReference(ref: $0.id) },
      prevSibling: node.prevSibling.map { JsonReference(ref: $0.id) },
      nextSibling: node.nextSibling.map { JsonReference(ref: $0.id) },
      children: enrichedChildren,
      attributes: attrs,
      parameterizedAttributes: node.parameterizedAttributes,
      actions: node.actions,
      bounds: node.bounds,
      zIndex: node.zIndex,
      timing: timingInfo
    )
  }

  // MARK: - Flat JSON Output

  private struct FlatJsonNode: Codable {
    let id: String
    let parent: JsonReference?
    let prevSibling: JsonReference?
    let nextSibling: JsonReference?
    let attributes: [String: AXSnapshotValue]
    let parameterizedAttributes: [String]
    let actions: [AXSnapshotAction]
    let bounds: CGRect?
    let zIndex: Int?

    enum CodingKeys: String, CodingKey {
      case id = "@id"
      case parent, prevSibling, nextSibling
      case attributes, parameterizedAttributes, actions
      case bounds, zIndex
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(id, forKey: .id)
      try container.encodeIfPresent(parent, forKey: .parent)
      try container.encodeIfPresent(prevSibling, forKey: .prevSibling)
      try container.encodeIfPresent(nextSibling, forKey: .nextSibling)
      try container.encode(attributes, forKey: .attributes)
      try container.encode(parameterizedAttributes, forKey: .parameterizedAttributes)
      try container.encode(actions, forKey: .actions)

      if let bounds = bounds {
        var boundsDict: [String: Double] = [:]
        boundsDict["x"] = bounds.origin.x
        boundsDict["y"] = bounds.origin.y
        boundsDict["width"] = bounds.width
        boundsDict["height"] = bounds.height
        try container.encode(boundsDict, forKey: .bounds)
      }

      try container.encodeIfPresent(zIndex, forKey: .zIndex)
    }
  }

  private func printFlatJsonNode(_ node: MutableNode, attributeFilter: Set<String>?) throws {
    // Filter attributes if needed
    let attrs: [String: AXSnapshotValue]
    if let filter = attributeFilter {
      attrs = node.attributes.filter { filter.contains($0.key) }
    } else {
      attrs = node.attributes
    }

    let flatNode = FlatJsonNode(
      id: node.id,
      parent: node.parent.map { JsonReference(ref: $0.id) },
      prevSibling: node.prevSibling.map { JsonReference(ref: $0.id) },
      nextSibling: node.nextSibling.map { JsonReference(ref: $0.id) },
      attributes: attrs,
      parameterizedAttributes: node.parameterizedAttributes,
      actions: node.actions,
      bounds: node.bounds,
      zIndex: node.zIndex
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    let jsonData = try encoder.encode(flatNode)
    if let jsonString = String(data: jsonData, encoding: .utf8) {
      // Indent each line by 2 spaces for array formatting
      let indented = jsonString.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n")
      print(indented, terminator: "")
    }
  }

  // MARK: - Helper Functions

  private func getAppName(_ node: AXSnapshotNode) -> String {
    if let title = extractStringValue(node.attributes["AXTitle"]) {
      return title
    }
    return "Unknown"
  }

  private func extractStringValue(_ value: AXSnapshotValue?) -> String? {
    guard let value = value else { return nil }
    if case .string(let s) = value {
      return s
    }
    return nil
  }

  private func formatValue(_ value: AXSnapshotValue) -> String {
    switch value {
    case .string(let s):
      return "\"\(s)\""
    case .number(let n):
      return "\(n)"
    case .bool(let b):
      return "\(b)"
    case .null:
      return "null"
    case .url(let u):
      return "url(\(u))"
    case .date(let d):
      return "date(\(d))"
    case .data(let d):
      return "data(\(d.prefix(20))...)"
    case .array(let arr):
      return "[\(arr.count) items]"
    case .dictionary(let dict):
      return "{\(dict.count) keys}"
    case .cgPoint(let x, let y):
      return "(\(Int(x)), \(Int(y)))"
    case .cgSize(let w, let h):
      return "\(Int(w))×\(Int(h))"
    case .cgRect(let x, let y, let w, let h):
      return "(\(Int(x)), \(Int(y))) \(Int(w))×\(Int(h))"
    case .cfRange(let loc, let len):
      return "[\(loc):\(len)]"
    case .elementReference(let ref):
      return "ref(\(ref))"
    case .attributedString(let desc):
      return "attributedString(\(desc.prefix(50))...)"
    case .cgPath(let desc):
      return "cgPath(\(desc.prefix(50))...)"
    case .unknown(let desc):
      return "unknown(\(desc))"
    }
  }

  private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter.string(from: date)
  }

  private func formatDuration(_ duration: TimeInterval) -> String {
    return String(format: "%.3fs", duration)
  }
}
