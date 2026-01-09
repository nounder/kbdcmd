@preconcurrency import ApplicationServices
import AppKit
import ArgumentParser
import Core
import Foundation

struct WatchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "watch",
    abstract: "Watch accessibility notifications from all elements",
    discussion: """
      Monitors accessibility notifications from all running applications and prints them in real-time.

      Performs a shallow traversal of each app's accessibility tree and registers for notifications
      on discovered elements.

      Filtering: Use logfmt-style queries to filter output
        field=value           # Exact match
        field!=value          # Not equal
        field~pattern         # Glob pattern (* and ?)
        field!~pattern        # Not matching pattern
        field>value           # Greater than (numeric)
        field<value           # Less than (numeric)

      Examples:
        kbdcmd watch                                  # Watch all apps
        kbdcmd watch --app Music                      # Watch only Music app
        kbdcmd watch --query 'app=Music'              # Filter by app
        kbdcmd watch -q 'app=Music' -q 'role!=AXStaticText'  # Multiple filters (AND)
        kbdcmd watch --query 'type~AXValue*'          # Pattern matching
        kbdcmd watch --timeout 10                     # Stop after 10 seconds
        kbdcmd watch --until 'type=AXWindowCreated'   # Stop when window created
      """
  )

  @Option(name: .long, help: "Maximum depth to traverse (default: 1)")
  var depth: Int = 1

  @Flag(name: .long, help: "Include element details in output")
  var verbose: Bool = false

  @Option(name: .shortAndLong, help: "Filter output with logfmt-style queries (e.g., app=Music role!=AXStaticText)")
  var query: [String] = []

  @Option(name: .long, help: "Stop after specified number of seconds")
  var timeout: Int?

  @Option(name: .long, help: "Stop when an event matches this query (e.g., type=AXValueChanged)")
  var until: [String] = []

  @Option(name: .shortAndLong, help: "Fields to output (e.g., -f time,app or -f _,label). Use _ for defaults (time,app,type,role,bounds). Available: time, app, type, role, desc, subrole, bounds, display, title, label, value")
  var field: [String] = []

  @MainActor
  func run() async throws {
    try Permissions.checkAccessibility()

    let queryFilter = try query.isEmpty ? nil : QueryFilter(conditions: query)
    let untilFilter = try until.isEmpty ? nil : QueryFilter(conditions: until)

    // Parse fields: support both "-f time,app" and "-f time -f app"
    // Use "_" to insert default fields at that position
    let defaultFields = ["time", "app", "type", "role", "bounds"]
    let fields: [String]
    if field.isEmpty {
      fields = defaultFields
    } else {
      fields = field.flatMap { $0.split(separator: ",").map(String.init) }
        .flatMap { $0 == "_" ? defaultFields : [$0] }
    }

    let watcher = NotificationWatcher(
      maxDepth: depth,
      verbose: verbose,
      fields: fields,
      queryFilter: queryFilter,
      untilFilter: untilFilter
    )

    watcher.start()

    // Calculate deadline if timeout specified
    let deadline: Date? = timeout.map { Date().addingTimeInterval(TimeInterval($0)) }

    // Run until cancelled, timeout, or until condition met
    try await withTaskCancellationHandler {
      while !Task.isCancelled && !watcher.shouldStop {
        if let deadline = deadline, Date() >= deadline {
          break
        }
        try await Task.sleep(for: .milliseconds(100))
      }
    } onCancel: {
      watcher.stop()
    }

    watcher.stop()
  }
}

private final class NotificationWatcher {
  private var observers: [(pid: pid_t, observer: AXObserver)] = []
  private var workspaceObservers: [NSObjectProtocol] = []
  private let maxDepth: Int
  private let verbose: Bool
  private let fields: [String]
  private let neededFields: Set<String>
  private let queryFilter: QueryFilter?
  private let untilFilter: QueryFilter?
  private(set) var shouldStop: Bool = false

  private static let allNotifications: [String] = [
    // Application notifications
    kAXApplicationActivatedNotification,
    kAXApplicationDeactivatedNotification,
    kAXApplicationHiddenNotification,
    kAXApplicationShownNotification,

    // Window notifications
    kAXWindowCreatedNotification,
    kAXWindowMovedNotification,
    kAXWindowResizedNotification,
    kAXWindowMiniaturizedNotification,
    kAXWindowDeminiaturizedNotification,
    kAXMainWindowChangedNotification,
    kAXFocusedWindowChangedNotification,

    // UI Element notifications
    kAXFocusedUIElementChangedNotification,
    kAXUIElementDestroyedNotification,
    kAXTitleChangedNotification,
    kAXValueChangedNotification,
    kAXSelectedTextChangedNotification,
    kAXSelectedChildrenChangedNotification,
    kAXSelectedRowsChangedNotification,
    kAXSelectedColumnsChangedNotification,
    kAXRowCountChangedNotification,
    kAXSelectedCellsChangedNotification,
    kAXUnitsChangedNotification,
    kAXSelectedChildrenMovedNotification,

    // Layout notifications
    kAXCreatedNotification,
    kAXMovedNotification,
    kAXResizedNotification,
    kAXLayoutChangedNotification,
    kAXAnnouncementRequestedNotification,

    // Menu notifications
    kAXMenuOpenedNotification,
    kAXMenuClosedNotification,
    kAXMenuItemSelectedNotification,

    // Drawer/sheet notifications
    kAXDrawerCreatedNotification,
    kAXSheetCreatedNotification,
    kAXHelpTagCreatedNotification,
  ]

  init(maxDepth: Int, verbose: Bool, fields: [String], queryFilter: QueryFilter? = nil, untilFilter: QueryFilter? = nil) {
    self.maxDepth = maxDepth
    self.verbose = verbose
    self.fields = fields
    self.queryFilter = queryFilter
    self.untilFilter = untilFilter

    // Compute all fields needed for output and filtering
    var needed = Set(fields)
    if let filter = queryFilter {
      needed.formUnion(filter.usedFields)
    }
    if let filter = untilFilter {
      needed.formUnion(filter.usedFields)
    }
    self.neededFields = needed
  }

  func start() {
    setupObserversForRunningApps()
    setupWorkspaceNotifications()
  }

  func stop() {
    removeObservers()
    removeWorkspaceNotifications()
  }

  private func setupWorkspaceNotifications() {
    let workspace = NSWorkspace.shared
    let launchObserver = workspace.notificationCenter.addObserver(
      forName: NSWorkspace.didLaunchApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
        return
      }
      self?.addObserverForApp(app, isLaunch: true)
    }
    workspaceObservers.append(launchObserver)

    let terminateObserver = workspace.notificationCenter.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
        return
      }
      self?.removeObserverForApp(app.processIdentifier)
    }
    workspaceObservers.append(terminateObserver)
  }

  private func removeWorkspaceNotifications() {
    for observer in workspaceObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    workspaceObservers.removeAll()
  }

  private func setupObserversForRunningApps() {
    let runningApps = NSWorkspace.shared.runningApplications

    for app in runningApps {
      addObserverForApp(app)
    }
  }

  private func addObserverForApp(_ app: NSRunningApplication, isLaunch: Bool = false) {
    guard app.activationPolicy == .regular else { return }

    let pid = app.processIdentifier
    let appName = app.localizedName ?? "Unknown"

    // Check if app matches query filter (if filtering by app)
    if let filter = queryFilter, !filter.matchesApp(appName) {
      return
    }

    // Check if we already have an observer for this pid
    if observers.contains(where: { $0.pid == pid }) {
      return
    }

    var observer: AXObserver?
    let refcon = Unmanaged.passUnretained(self).toOpaque()

    let result = AXObserverCreate(
      pid,
      { (_, element, notification, refcon) in
        guard let refcon = refcon else { return }
        let watcher = Unmanaged<NotificationWatcher>.fromOpaque(refcon).takeUnretainedValue()
        watcher.handleNotification(element: element, notification: notification as String)
      },
      &observer
    )

    guard result == .success, let observer = observer else {
      return
    }

    let appElement = AXUIElementCreateApplication(pid)
    var elementCount = 0

    // Traverse and register notifications on elements
    traverseAndRegister(
      element: appElement,
      observer: observer,
      refcon: refcon,
      depth: 0,
      elementCount: &elementCount
    )

    CFRunLoopAddSource(
      CFRunLoopGetCurrent(),
      AXObserverGetRunLoopSource(observer),
      .defaultMode
    )

    observers.append((pid: pid, observer: observer))

    if isLaunch {
      if verbose {
        output("[\(timestamp())] Launch detected: \(appName) (pid: \(pid)) - \(elementCount) elements")
      } else {
        output("[\(timestamp())] Launch detected: \(appName)")
      }
    }
  }

  private func traverseAndRegister(
    element: AXUIElement,
    observer: AXObserver,
    refcon: UnsafeMutableRawPointer,
    depth: Int,
    elementCount: inout Int
  ) {
    // Register all notifications on this element
    for notification in Self.allNotifications {
      AXObserverAddNotification(observer, element, notification as CFString, refcon)
    }
    elementCount += 1

    // Stop at max depth
    guard depth < maxDepth else { return }

    // Get children
    var childrenRef: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
          let children = childrenRef as? [AXUIElement]
    else {
      return
    }

    for child in children {
      traverseAndRegister(
        element: child,
        observer: observer,
        refcon: refcon,
        depth: depth + 1,
        elementCount: &elementCount
      )
    }
  }

  private func removeObserverForApp(_ pid: pid_t) {
    guard let index = observers.firstIndex(where: { $0.pid == pid }) else {
      return
    }

    let entry = observers[index]
    CFRunLoopRemoveSource(
      CFRunLoopGetCurrent(),
      AXObserverGetRunLoopSource(entry.observer),
      .defaultMode
    )
    observers.remove(at: index)
  }

  private func removeObservers() {
    for entry in observers {
      CFRunLoopRemoveSource(
        CFRunLoopGetCurrent(),
        AXObserverGetRunLoopSource(entry.observer),
        .defaultMode
      )
    }
    observers.removeAll()
  }

  private func handleNotification(element: AXUIElement, notification: String) {
    // When a new window is created, traverse and register notifications on its elements
    if notification == kAXWindowCreatedNotification {
      var pid: pid_t = 0
      AXUIElementGetPid(element, &pid)
      if let entry = observers.first(where: { $0.pid == pid }) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var elementCount = 0
        traverseAndRegister(
          element: element,
          observer: entry.observer,
          refcon: refcon,
          depth: 0,
          elementCount: &elementCount
        )
        if verbose {
          let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Unknown"
          output("[\(timestamp())] New window in \(appName) - registered \(elementCount) elements")
        }
      }
    }

    // Get element info for context
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)

    // Only query attributes that are needed for output or filtering
    let bounds = neededFields.contains("bounds") || neededFields.contains("display") ? getBounds(element) : nil
    let display = neededFields.contains("display") ? bounds.flatMap { getDisplayIndex(for: $0.origin) } : nil

    let notif = WatchNotification(
      time: timestamp(),
      type: extractNotificationType(notification),
      app: NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Unknown",
      role: neededFields.contains("role") ? (getAttr(element, kAXRoleAttribute) ?? "Unknown") : "Unknown",
      desc: neededFields.contains("desc") ? getAttr(element, kAXRoleDescriptionAttribute) : nil,
      subrole: neededFields.contains("subrole") ? getAttr(element, kAXSubroleAttribute) : nil,
      title: neededFields.contains("title") ? getAttr(element, kAXTitleAttribute) : nil,
      label: neededFields.contains("label") ? getAttr(element, kAXDescriptionAttribute) : nil,
      value: neededFields.contains("value") ? getAttr(element, kAXValueAttribute) : nil,
      bounds: bounds,
      display: display
    )

    // Apply query filter before outputting
    if let filter = queryFilter {
      guard filter.matches(notif) else { return }
    }

    output(notif.format(fields: fields))

    // Check if we should stop (after outputting the matching event)
    if let untilFilter = untilFilter, untilFilter.matches(notif) {
      shouldStop = true
    }
  }

  private func getAttr(_ element: AXUIElement, _ attr: String) -> String? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else {
      return nil
    }
    return value as? String
  }

  private func getBounds(_ element: AXUIElement) -> CGRect? {
    var posValue: AnyObject?
    var sizeValue: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
          CFGetTypeID(posValue as CFTypeRef) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue as CFTypeRef) == AXValueGetTypeID() else {
      return nil
    }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
      return nil
    }
    return CGRect(origin: point, size: size)
  }

  /// Returns the display index (0 = main) containing the given point.
  /// Note: This returns physical display index, not macOS Space ID.
  /// Space IDs require private APIs (CGSConnection/SkyLight) which we don't use.
  private func getDisplayIndex(for point: CGPoint) -> Int? {
    let screens = NSScreen.screens
    for (index, screen) in screens.enumerated() {
      if screen.frame.contains(point) {
        return index
      }
    }
    return nil
  }

  private func extractNotificationType(_ notification: String) -> String {
    // Convert "kAXValueChangedNotification" -> "AXValueChanged"
    // Remove "k" prefix and "Notification" suffix
    var result = notification
    if result.hasPrefix("k") {
      result = String(result.dropFirst())
    }
    if result.hasSuffix("Notification") {
      result = String(result.dropLast("Notification".count))
    }
    return result
  }

  private func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
  }

  private func output(_ message: String) {
    print(message)
    fflush(stdout)
  }
}

private struct WatchNotification {
  let time: String
  let type: String
  let app: String
  let role: String
  let desc: String?
  let subrole: String?
  let title: String?
  let label: String?
  let value: String?
  let bounds: CGRect?
  let display: Int?

  func field(_ name: String) -> String? {
    switch name {
    case "time": return time
    case "type": return type
    case "app": return app
    case "role": return role
    case "desc": return desc
    case "subrole": return subrole
    case "title": return title
    case "label": return label
    case "value": return value
    case "bounds": return bounds.map { formatBounds($0) }
    case "display": return display.map { String($0) }
    default: return nil
    }
  }

  private func formatBounds(_ rect: CGRect) -> String {
    "\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width)),\(Int(rect.height))"
  }

  func format(fields: [String], truncateLength: Int = 50) -> String {
    var parts: [String] = []

    for fieldName in fields {
      let value = field(fieldName) ?? ""
      let escaped = escape(truncate(value, max: truncateLength))
      parts.append("\(fieldName)=\"\(escaped)\"")
    }

    return parts.joined(separator: "\t")
  }

  private func escape(_ string: String) -> String {
    string
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\r\n", with: "\\r\\n")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }

  private func truncate(_ string: String, max: Int) -> String {
    string.count > max ? String(string.prefix(max)) + "..." : string
  }
}

private struct QueryFilter {
  enum MatchOperator {
    case equals
    case notEquals
    case glob
    case notGlob
    case greaterThan
    case lessThan
  }

  struct Condition {
    let field: String
    let op: MatchOperator
    let pattern: String

    func matches(_ notification: WatchNotification) -> Bool {
      guard let value = notification.field(field) else { return false }
      return matchesValue(value)
    }

    func matchesValue(_ value: String) -> Bool {
      switch op {
      case .equals:
        return value == pattern
      case .notEquals:
        return value != pattern
      case .glob:
        return matchesGlob(value: value, glob: pattern)
      case .notGlob:
        return !matchesGlob(value: value, glob: pattern)
      case .greaterThan:
        return (Double(value) ?? 0) > (Double(pattern) ?? 0)
      case .lessThan:
        return (Double(value) ?? 0) < (Double(pattern) ?? 0)
      }
    }

    private func matchesGlob(value: String, glob: String) -> Bool {
      let regex = NSRegularExpression.escapedPattern(for: glob)
        .replacingOccurrences(of: "\\*", with: ".*")
        .replacingOccurrences(of: "\\?", with: ".")
      guard let regex = try? NSRegularExpression(pattern: "^\(regex)$") else {
        return false
      }
      return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
  }

  let conditions: [Condition]

  init(conditions: [String]) throws {
    var parsed: [Condition] = []
    for condition in conditions {
      let parts = condition.split(separator: " ", omittingEmptySubsequences: true)
      for part in parts {
        let condition = try QueryFilter.parseCondition(String(part))
        parsed.append(condition)
      }
    }
    self.conditions = parsed
  }

  static func parseCondition(_ condition: String) throws -> Condition {
    let operators: [(String, MatchOperator)] = [
      ("!=", .notEquals),
      ("!~", .notGlob),
      ("<=", .lessThan),
      (">=", .greaterThan),
      ("=", .equals),
      ("~", .glob),
      (">", .greaterThan),
      ("<", .lessThan),
    ]

    for (opString, op) in operators {
      guard let range = condition.range(of: opString) else { continue }
      let field = String(condition[..<range.lowerBound])
      var pattern = String(condition[range.upperBound...])

      // Validate field name (non-empty, alphanumeric + underscore)
      guard !field.isEmpty && field.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
        throw NSError(domain: "QueryFilter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid field name: '\(field)'. Must be alphanumeric."])
      }

      // Check for invalid double operators like ==
      if opString == "=" && pattern.hasPrefix("=") {
        throw NSError(domain: "QueryFilter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid operator '=='. Did you mean '='? Use operators: =, !=, ~, !~, >, <"])
      }

      // Remove surrounding quotes if present
      if pattern.hasPrefix("\"") && pattern.hasSuffix("\"") {
        pattern = String(pattern.dropFirst().dropLast())
      }

      return Condition(field: field, op: op, pattern: pattern)
    }

    throw NSError(domain: "QueryFilter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid query condition: '\(condition)'. Use operators: =, !=, ~, !~, >, <"])
  }

  func matches(_ notification: WatchNotification) -> Bool {
    conditions.allSatisfy { $0.matches(notification) }
  }

  func matchesApp(_ appName: String) -> Bool {
    let appConditions = conditions.filter { $0.field == "app" }
    guard !appConditions.isEmpty else { return true }
    return appConditions.allSatisfy { $0.matchesValue(appName) }
  }

  var usedFields: Set<String> {
    Set(conditions.map { $0.field })
  }
}
