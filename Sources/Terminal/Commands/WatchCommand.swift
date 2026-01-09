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

      Examples:
        kbdcmd watch                    # Watch all apps
        kbdcmd watch --app Music        # Watch only Music app
        kbdcmd watch --depth 2          # Traverse 2 levels deep
      """
  )

  @Option(name: .long, help: "Filter by application name or bundle ID")
  var app: String?

  @Option(name: .long, help: "Maximum depth to traverse (default: 1)")
  var depth: Int = 1

  @Flag(name: .long, help: "Include element details in output")
  var verbose: Bool = false

  @MainActor
  func run() async throws {
    try Permissions.checkAccessibility()

    let watcher = NotificationWatcher(
      appFilter: app,
      maxDepth: depth,
      verbose: verbose
    )

    watcher.start()

    // Run indefinitely
    try await withTaskCancellationHandler {
      while !Task.isCancelled {
        try await Task.sleep(for: .seconds(1))
      }
    } onCancel: {
      watcher.stop()
    }
  }
}

private final class NotificationWatcher {
  private var observers: [(pid: pid_t, observer: AXObserver)] = []
  private var workspaceObservers: [NSObjectProtocol] = []
  private let appFilter: String?
  private let maxDepth: Int
  private let verbose: Bool

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

  init(appFilter: String?, maxDepth: Int, verbose: Bool) {
    self.appFilter = appFilter
    self.maxDepth = maxDepth
    self.verbose = verbose
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
    let launchObserver = NotificationCenter.default.addObserver(
      forName: NSWorkspace.didLaunchApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
        return
      }
      self?.addObserverForApp(app)
    }
    workspaceObservers.append(launchObserver)

    let terminateObserver = NotificationCenter.default.addObserver(
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
      NotificationCenter.default.removeObserver(observer)
    }
    workspaceObservers.removeAll()
  }

  private func setupObserversForRunningApps() {
    let runningApps = NSWorkspace.shared.runningApplications

    for app in runningApps {
      addObserverForApp(app)
    }
  }

  private func addObserverForApp(_ app: NSRunningApplication) {
    guard app.activationPolicy == .regular else { return }

    if let filter = appFilter {
      let appName = app.localizedName ?? ""
      let bundleId = app.bundleIdentifier ?? ""
      let matches = appName.localizedCaseInsensitiveContains(filter)
        || bundleId.localizedCaseInsensitiveContains(filter)
      if !matches {
        return
      }
    }

    let pid = app.processIdentifier
    let appName = app.localizedName ?? "Unknown"

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

    if verbose {
      output("[\(timestamp())] Watching \(appName) (pid: \(pid)) - \(elementCount) elements")
    } else {
      output("[\(timestamp())] Watching \(appName)")
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
    // Get element info for context
    let role = getAttr(element, kAXRoleAttribute) ?? "Unknown"
    let title = getAttr(element, kAXTitleAttribute)
    let description = getAttr(element, kAXDescriptionAttribute)
    let value = getAttr(element, kAXValueAttribute)

    // Get app name from element
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Unknown"

    // Extract notification type (e.g., "kAXValueChangedNotification" -> "AXValueChanged")
    let notificationType = extractNotificationType(notification)

    // Build structured output with quoted values
    var output = "time=\"\(timestamp())\" type=\"\(escapeQuoted(notificationType))\" app=\"\(escapeQuoted(appName))\" role=\"\(escapeQuoted(role))\""

    if verbose {
      if let title = title, !title.isEmpty {
        output += " title=\"\(escapeQuoted(truncate(title)))\""
      }
      if let description = description, !description.isEmpty {
        output += " desc=\"\(escapeQuoted(truncate(description)))\""
      }
      if let value = value, !value.isEmpty {
        output += " value=\"\(escapeQuoted(truncate(value)))\""
      }
    } else {
      // Show the most useful identifier
      let identifier = title ?? description ?? value
      if let id = identifier, !id.isEmpty {
        output += " text=\"\(escapeQuoted(truncate(id)))\""
      }
    }

    self.output(output)
  }

  private func getAttr(_ element: AXUIElement, _ attr: String) -> String? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else {
      return nil
    }
    return value as? String
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

  private func escapeQuoted(_ string: String) -> String {
    // Escape backslashes and quotes for quoted values
    return string
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }

  private func truncate(_ string: String, max: Int = 50) -> String {
    string.count > max ? String(string.prefix(max)) + "..." : string
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
