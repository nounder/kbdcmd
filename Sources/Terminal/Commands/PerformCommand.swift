@preconcurrency import ApplicationServices
import AppKit
import ArgumentParser
import Carbon
import Core
import Foundation

@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow_Perform(_ axUiElement: AXUIElement, _ id: inout CGWindowID) -> AXError

struct PerformCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "perform",
    abstract: "Perform accessibility actions or type text",
    discussion: """
      Performs an accessibility action on an element at the specified coordinates,
      types text at the current focus, presses a special key, or performs a mouse click.

      Examples:
        kbdcmd perform click @100,200                     # Mouse click at coordinates
        kbdcmd perform click @100,200,50,30               # Click center of bounds (125,215)
        kbdcmd perform move @100,200                      # Move cursor to coordinates (hover)
        kbdcmd perform AXPress @100,200                   # Trigger AXPress on element
        kbdcmd perform AXPress @100,200 --app Spotify     # AXPress in specific app's window
        kbdcmd perform AXShowMenu @100,200                # Show context menu
        kbdcmd perform type "Hello World"                 # Type text at current focus
        kbdcmd perform type "<ctrl-a>" "<ctrl-k>" "hello" # Chords and text with 50ms delay
        kbdcmd perform type "<cmd-c>" "<cmd-v>"           # Copy and paste
        kbdcmd perform key return                         # Press Enter/Return key
        kbdcmd perform key tab                            # Press Tab key

      Coordinates require @ prefix: @x,y or @x,y,w,h (bounds, clicks center).
      Type operation supports chords (<modifier-key>) and plain text.
      Modifiers: ctrl/c, alt/opt/m, shift/s, cmd/super/win. Separator: - or +.
      """
  )

  @Argument(help: "Operation: click, move, type, key, or an AX action (e.g., AXPress, AXShowMenu)")
  var operation: String = ""

  @Argument(parsing: .remaining, help: "Coordinates, text/chords for type, or key name")
  var operands: [String] = []

  @Option(name: .shortAndLong, help: "Target specific app by name or bundle ID (focuses app first, AX actions only)")
  var app: String?

  @Option(name: .long, help: "Target specific window by title (AX actions only, auto-detected if omitted)")
  var title: String?

  @Option(name: .long, help: "Target specific app by process ID (AX actions only, auto-detected if omitted)")
  var pid: pid_t?

  @Option(name: .long, help: "Target specific window by CGWindowID (AX actions only, auto-detected if omitted)")
  var cgid: Int?

  @Flag(name: .long, help: "Print debug information")
  var debug: Bool = false

  @Flag(name: .long, help: "Run walker command after action completes (0.2s delay)")
  var walk: Bool = false

  @Flag(name: .long, help: "Perform the action twice (e.g., double-click)")
  var double: Bool = false

  @Option(name: .long, help: "Delay between keystrokes in seconds (default: 0.05, type operation only)")
  var delay: Double = 0.05

  @Option(name: .long, help: "Wait time in seconds before starting (type operation only)")
  var wait: Double = 0

  @Flag(name: .long, help: "Clear input field before typing (select all + delete)")
  var clear: Bool = false

  @MainActor
  func run() async throws {
    try Permissions.checkAccessibility()

    // Validate filter exclusivity
    let filterCount = [app != nil, title != nil, pid != nil, cgid != nil].filter { $0 }.count
    if filterCount > 1 {
      throw ValidationError("--app, --title, --pid, and --cgid are mutually exclusive")
    }

    guard !operation.isEmpty else {
      throw ValidationError("Operation required (click, move, type, key, or AX action)")
    }

    let op = operation.lowercased()

    // Handle type operation
    if op == "type" {
      guard !operands.isEmpty else {
        throw ValidationError("Text argument required for type operation")
      }
      if wait > 0 {
        usleep(UInt32(wait * 1_000_000))
      }
      if clear {
        try KeyEmitter.emit(cmd(.char("a")))
        usleep(20000)
        try KeyEmitter.emit(Keystroke(.delete))
        usleep(50000)
      }
      try performTyping(operands, delay: delay)
      return
    }

    // Handle key operation
    if op == "key" {
      guard let keyName = operands.first else {
        throw ValidationError("Key name required for key operation")
      }
      try performKeyPress(keyName)
      return
    }

    // Handle click operation
    if op == "click" {
      guard let coords = operands.first else {
        throw ValidationError("Coordinates required for click operation")
      }
      try performClick(coords)
      return
    }

    // Handle move operation
    if op == "move" {
      guard let coords = operands.first else {
        throw ValidationError("Coordinates required for move operation")
      }
      try performMove(coords)
      return
    }

    // Assume it's an AX action (e.g., AXPress, AXShowMenu)
    let actionName = operation  // Use original case for AX actions
    guard let coords = operands.first else {
      throw ValidationError("Coordinates required for \(actionName) action")
    }

    let (point, targetBounds) = try parseCoordinates(coords)
    let x = point.x
    let y = point.y

    // Get the target window
    let root: AXUIElement
    if let appFilter = app {
      // Ensure the app is focused first
      try ensureAppFrontmost(appFilter)
      guard let window = findWindowByApp(appFilter) else {
        throw ValidationError("No window found for app '\(appFilter)'")
      }
      root = window
    } else if let titleFilter = title {
      guard let window = findWindowByTitle(titleFilter) else {
        throw ValidationError("No window found with title '\(titleFilter)'")
      }
      root = window
    } else if let pidFilter = pid {
      guard let window = findWindowByPid(pidFilter) else {
        throw ValidationError("No window found for pid \(pidFilter)")
      }
      root = window
    } else if let cgidFilter = cgid {
      guard let window = findWindowByCGID(CGWindowID(cgidFilter)) else {
        throw ValidationError("No window found with cgid \(cgidFilter)")
      }
      root = window
    } else {
      // Auto-detect window at coordinates
      guard let (window, runningApp) = findWindowAtPoint(point) else {
        throw ValidationError("No window found at (\(Int(x)),\(Int(y)))")
      }
      AXUIElementPerformAction(window, kAXRaiseAction as CFString)
      runningApp.activate()
      usleep(50000)
      root = window
    }

    // Find element at coordinates that supports the action
    if debug {
      print("Looking for action '\(actionName)' at (\(Int(x)),\(Int(y)))")
    }
    let (element, availableActions) = findElementAtPoint(root: root, point: point, action: actionName, targetBounds: targetBounds, debug: debug)
    guard let element = element else {
      if availableActions.isEmpty {
        throw ValidationError("No element found at (\(Int(x)),\(Int(y)))")
      } else {
        throw ValidationError("Action '\(actionName)' not available. Available: \(availableActions.joined(separator: ", "))")
      }
    }

    // Get CGID before performing action (for --walk)
    var windowCGID = CGWindowID()
    _ = _AXUIElementGetWindow_Perform(root, &windowCGID)

    // Perform the action
    let result = AXUIElementPerformAction(element, actionName as CFString)
    // Allow cannotComplete (-25204) and attributeUnsupported (-25205) since the action often succeeds
    // but the UI changes before confirmation can be obtained (e.g., opening a new tab in Ghostty)
    if result != .success && result != .cannotComplete && result != .attributeUnsupported {
      throw ValidationError("Failed to perform action '\(actionName)': error \(result.rawValue)")
    }

    print("Performed \(actionName) at (\(Int(x)),\(Int(y)))")

    // Run walker if --walk flag is set
    if walk && windowCGID != 0 {
      usleep(500000)  // 0.5s delay
      let walker = try TreeCommand.parse(["--cgid", String(windowCGID)])
      try await walker.run()
    }
  }

  private func performTyping(_ inputs: [String], delay: Double) throws {
    let items = try KeystrokeParser.parseMultiple(inputs)
    try KeyEmitter.emit(items, delay: delay)
  }

  private func performKeyPress(_ keyName: String) throws {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
      throw ValidationError("Failed to create event source")
    }

    // Map key names to key codes
    let keyCodeMap: [String: CGKeyCode] = [
      "return": 36, "enter": 36,
      "tab": 48,
      "space": 49,
      "delete": 51, "backspace": 51,
      "escape": 53, "esc": 53,
      "up": 126,
      "down": 125,
      "left": 123,
      "right": 124,
      "home": 115,
      "end": 119,
      "pageup": 116,
      "pagedown": 121,
      "f1": 122, "f2": 120, "f3": 99, "f4": 118,
      "f5": 96, "f6": 97, "f7": 98, "f8": 100,
      "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    guard let keyCode = keyCodeMap[keyName.lowercased()] else {
      let validKeys = keyCodeMap.keys.sorted().joined(separator: ", ")
      throw ValidationError("Unknown key '\(keyName)'. Valid keys: \(validKeys)")
    }

    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
      throw ValidationError("Failed to create key event")
    }

    keyDown.post(tap: .cghidEventTap)
    usleep(50000)
    keyUp.post(tap: .cghidEventTap)

    print("Pressed: \(keyName)")
  }

  private func performClick(_ coords: String) throws {
    let (point, _) = try parseCoordinates(coords)
    let x = point.x
    let y = point.y

    // Ensure target app is frontmost if specified
    if let appFilter = app {
      try ensureAppFrontmost(appFilter)
    } else if let (window, runningApp) = findWindowAtPoint(point) {
      // Raise and activate the window at coordinates
      AXUIElementPerformAction(window, kAXRaiseAction as CFString)
      runningApp.activate()
      usleep(50000)
    }

    guard let source = CGEventSource(stateID: .hidSystemState) else {
      throw ValidationError("Failed to create event source")
    }

    // Move mouse to position first (some apps need this)
    if let moveEvent = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                mouseCursorPosition: point, mouseButton: .left) {
      moveEvent.post(tap: .cghidEventTap)
      usleep(10000) // 10ms delay
    }

    // Mouse down
    guard let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                   mouseCursorPosition: point, mouseButton: .left) else {
      throw ValidationError("Failed to create mouse down event")
    }

    // Mouse up
    guard let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                                 mouseCursorPosition: point, mouseButton: .left) else {
      throw ValidationError("Failed to create mouse up event")
    }

    mouseDown.post(tap: .cghidEventTap)
    usleep(50000) // 50ms delay between down and up
    mouseUp.post(tap: .cghidEventTap)

    if double {
      usleep(50000) // 50ms delay before second click
      mouseDown.post(tap: .cghidEventTap)
      usleep(50000)
      mouseUp.post(tap: .cghidEventTap)
      print("Double-clicked at (\(Int(x)),\(Int(y)))")
    } else {
      print("Clicked at (\(Int(x)),\(Int(y)))")
    }
  }

  private func performMove(_ coords: String) throws {
    let (point, _) = try parseCoordinates(coords)
    let x = point.x
    let y = point.y

    // Ensure target app is frontmost if specified
    if let appFilter = app {
      try ensureAppFrontmost(appFilter)
    } else if let (window, runningApp) = findWindowAtPoint(point) {
      // Raise and activate the window at coordinates
      AXUIElementPerformAction(window, kAXRaiseAction as CFString)
      runningApp.activate()
      usleep(100000)
    }

    // Use CGWarpMouseCursorPosition for reliable cursor movement
    CGWarpMouseCursorPosition(point)

    // Also post a mouse move event to trigger hover effects
    if let source = CGEventSource(stateID: .hidSystemState),
       let moveEvent = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                mouseCursorPosition: point, mouseButton: .left) {
      moveEvent.post(tap: .cghidEventTap)
    }

    print("Moved to (\(Int(x)),\(Int(y)))")
  }

  private func parseCoordinates(_ coords: String) throws -> (point: CGPoint, targetBounds: CGRect?) {
    // Coordinates must start with @ prefix
    guard coords.hasPrefix("@") else {
      throw ValidationError("Coordinates must start with @, e.g., @100,200 or @100,200,50,30")
    }

    let coordStr = String(coords.dropFirst())
    let parts = coordStr.split(separator: ",")

    if parts.count == 2 {
      // Simple x,y format
      guard let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
            let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) else {
        throw ValidationError("Coordinates must be in format: x,y (e.g., 100,200)")
      }
      return (CGPoint(x: x, y: y), nil)
    } else if parts.count == 4 {
      // Bounds format: x,y,width,height - calculate center and preserve bounds
      guard let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
            let y = Double(parts[1].trimmingCharacters(in: .whitespaces)),
            let width = Double(parts[2].trimmingCharacters(in: .whitespaces)),
            let height = Double(parts[3].trimmingCharacters(in: .whitespaces)) else {
        throw ValidationError("Bounds must be in format: x,y,width,height (e.g., 100,200,50,30)")
      }
      let centerX = x + width / 2
      let centerY = y + height / 2
      let targetBounds = CGRect(x: x, y: y, width: width, height: height)
      return (CGPoint(x: centerX, y: centerY), targetBounds)
    } else {
      throw ValidationError("Coordinates must be x,y or bounds x,y,width,height")
    }
  }

  private func findElementAtPoint(root: AXUIElement, point: CGPoint, action: String, targetBounds: CGRect? = nil, debug: Bool = false) -> (element: AXUIElement?, availableActions: [String]) {
    var bestMatch: AXUIElement? = nil
    var bestArea: CGFloat = CGFloat.infinity
    var bestMatchActions: [String] = []

    var stack: [AXUIElement] = [root]

    while let element = stack.popLast() {
      // Get bounds first
      if let bounds = getBounds(element) {
        let actions = getActions(element)

        // When targetBounds is provided, search by bounds matching (for off-screen elements)
        // Otherwise, use point containment
        let shouldCheck: Bool
        if let target = targetBounds {
          // Match if bounds are approximately equal (within 2px tolerance)
          shouldCheck = abs(bounds.origin.x - target.origin.x) <= 2 &&
                        abs(bounds.origin.y - target.origin.y) <= 2 &&
                        abs(bounds.width - target.width) <= 2 &&
                        abs(bounds.height - target.height) <= 2
        } else {
          shouldCheck = bounds.contains(point)
        }

        if debug {
          let role = getRole(element) ?? "unknown"
          if shouldCheck {
            print("  [\(role)] bounds=\(Int(bounds.origin.x)),\(Int(bounds.origin.y)),\(Int(bounds.width)),\(Int(bounds.height)) actions=\(actions) MATCH")
          }
        }

        if shouldCheck {
          // Prefer smaller elements (more specific)
          let area = bounds.width * bounds.height
          if area < bestArea {
            bestMatch = element
            bestArea = area
            bestMatchActions = actions
          }
        }

        // When searching by bounds, traverse entire tree; otherwise only traverse if point is contained
        if targetBounds != nil || bounds.contains(point) {
          let children = getChildren(element)
          for child in children {
            stack.append(child)
          }
        }
      }
    }

    if let match = bestMatch, bestMatchActions.contains(action) {
      return (match, bestMatchActions)
    }
    return (nil, bestMatchActions)
  }

  private func getRole(_ element: AXUIElement) -> String? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
      return nil
    }
    return value as? String
  }

  private func findWindowByApp(_ appFilter: String) -> AXUIElement? {
    return findWindowAndAppByFilter(appFilter)?.0
  }

  private func findWindowByTitle(_ titleFilter: String) -> AXUIElement? {
    return findWindowAndAppByTitle(titleFilter)?.0
  }

  private func findWindowByPid(_ pidFilter: pid_t) -> AXUIElement? {
    return findWindowAndAppByPid(pidFilter)?.0
  }

  private func findWindowByCGID(_ targetCGID: CGWindowID) -> AXUIElement? {
    return findWindowAndAppByCGID(targetCGID)?.0
  }

  private func findWindowAndAppByFilter(_ appFilter: String) -> (AXUIElement, NSRunningApplication)? {
    let runningApps = NSWorkspace.shared.runningApplications

    for app in runningApps {
      guard let appName = app.localizedName,
            app.activationPolicy == .regular
      else {
        continue
      }

      let appNameMatches = appName.localizedCaseInsensitiveContains(appFilter)
      let bundleIdMatches = app.bundleIdentifier?.localizedCaseInsensitiveContains(appFilter) ?? false

      if !appNameMatches && !bundleIdMatches {
        continue
      }

      let axApp = AXUIElementCreateApplication(app.processIdentifier)

      guard let axWindows = axApp.get(Ax.windowsAttr) else {
        continue
      }

      for axWindow in axWindows {
        guard axWindow.containingWindowId() != nil else {
          continue
        }

        let role = axWindow.get(Ax.roleAttr)
        if let role = role, role != "AXWindow" {
          continue
        }

        let subrole = axWindow.get(Ax.subroleAttr)
        if let subrole = subrole {
          let excludedSubroles = ["AXSystemDialog", "AXDialog", "AXUnknown"]
          if excludedSubroles.contains(subrole) {
            continue
          }
        }

        let size = axWindow.get(Ax.sizeAttr)
        guard let size = size else {
          continue
        }

        if size.width < 100 || size.height < 100 {
          continue
        }

        let windowTitle = axWindow.get(Ax.titleAttr) ?? ""
        let isMinimized = axWindow.get(Ax.minimizedAttr) ?? false

        if isMinimized {
          continue
        }

        if windowTitle.isEmpty && !isMinimized {
          continue
        }

        return (axWindow, app)
      }
    }
    return nil
  }

  private func findWindowAndAppByTitle(_ titleFilter: String) -> (AXUIElement, NSRunningApplication)? {
    let runningApps = NSWorkspace.shared.runningApplications

    for app in runningApps {
      guard app.activationPolicy == .regular else {
        continue
      }

      let axApp = AXUIElementCreateApplication(app.processIdentifier)

      guard let axWindows = axApp.get(Ax.windowsAttr) else {
        continue
      }

      for axWindow in axWindows {
        guard axWindow.containingWindowId() != nil else {
          continue
        }

        let role = axWindow.get(Ax.roleAttr)
        if let role = role, role != "AXWindow" {
          continue
        }

        let subrole = axWindow.get(Ax.subroleAttr)
        if let subrole = subrole {
          let excludedSubroles = ["AXSystemDialog", "AXDialog", "AXUnknown"]
          if excludedSubroles.contains(subrole) {
            continue
          }
        }

        let size = axWindow.get(Ax.sizeAttr)
        guard let size = size else {
          continue
        }

        if size.width < 100 || size.height < 100 {
          continue
        }

        let windowTitle = axWindow.get(Ax.titleAttr) ?? ""
        let isMinimized = axWindow.get(Ax.minimizedAttr) ?? false

        if isMinimized {
          continue
        }

        if windowTitle.localizedCaseInsensitiveContains(titleFilter) {
          return (axWindow, app)
        }
      }
    }
    return nil
  }

  private func findWindowAndAppByPid(_ pidFilter: pid_t) -> (AXUIElement, NSRunningApplication)? {
    guard let app = NSRunningApplication(processIdentifier: pidFilter),
          app.activationPolicy == .regular else {
      return nil
    }

    let axApp = AXUIElementCreateApplication(pidFilter)

    guard let axWindows = axApp.get(Ax.windowsAttr) else {
      return nil
    }

    for axWindow in axWindows {
      guard axWindow.containingWindowId() != nil else {
        continue
      }

      let role = axWindow.get(Ax.roleAttr)
      if let role = role, role != "AXWindow" {
        continue
      }

      let subrole = axWindow.get(Ax.subroleAttr)
      if let subrole = subrole {
        let excludedSubroles = ["AXSystemDialog", "AXDialog", "AXUnknown"]
        if excludedSubroles.contains(subrole) {
          continue
        }
      }

      let size = axWindow.get(Ax.sizeAttr)
      guard let size = size else {
        continue
      }

      if size.width < 100 || size.height < 100 {
        continue
      }

      let windowTitle = axWindow.get(Ax.titleAttr) ?? ""
      let isMinimized = axWindow.get(Ax.minimizedAttr) ?? false

      if isMinimized {
        continue
      }

      if windowTitle.isEmpty && !isMinimized {
        continue
      }

      return (axWindow, app)
    }
    return nil
  }

  private func findWindowAndAppByCGID(_ targetCGID: CGWindowID) -> (AXUIElement, NSRunningApplication)? {
    for app in NSWorkspace.shared.runningApplications {
      guard app.activationPolicy == .regular else { continue }

      let axApp = AXUIElementCreateApplication(app.processIdentifier)
      var windowsRef: AnyObject?
      guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
            let windows = windowsRef as? [AXUIElement] else {
        continue
      }

      for window in windows {
        var cgWindowId = CGWindowID()
        if _AXUIElementGetWindow_Perform(window, &cgWindowId) == .success && cgWindowId == targetCGID {
          return (window, app)
        }
      }
    }
    return nil
  }

  private func findWindowAtPoint(_ point: CGPoint) -> (AXUIElement, NSRunningApplication)? {
    // Get all on-screen windows sorted by z-index (front to back)
    let windowsInfo = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)

    guard let windowList = windowsInfo as? [[String: Any]] else {
      return nil
    }

    // Windows are already in z-order (front to back), find the topmost one containing the point
    for windowDict in windowList {
      guard let windowId = windowDict[kCGWindowNumber as String] as? CGWindowID,
            let pid = windowDict[kCGWindowOwnerPID as String] as? pid_t,
            let bounds = windowDict[kCGWindowBounds as String] as? [String: Any],
            let x = bounds["X"] as? CGFloat,
            let y = bounds["Y"] as? CGFloat,
            let width = bounds["Width"] as? CGFloat,
            let height = bounds["Height"] as? CGFloat else {
        continue
      }

      let windowRect = CGRect(x: x, y: y, width: width, height: height)

      // Check if point is within this window
      if windowRect.contains(point) {
        // Get the running app for this pid
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular else {
          continue
        }

        // Get AX window for this window ID
        let axApp = AXUIElementCreateApplication(pid)
        guard let axWindows = axApp.get(Ax.windowsAttr) else {
          continue
        }

        for axWindow in axWindows {
          if axWindow.containingWindowId() == windowId {
            return (axWindow, app)
          }
        }
      }
    }

    return nil
  }

  private func getChildren(_ element: AXUIElement) -> [AXUIElement] {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
      return []
    }
    return (value as? [AXUIElement]) ?? []
  }

  private func getActions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success,
          let actionNames = names as? [String] else {
      return []
    }
    return actionNames
      .compactMap { $0.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) }
      .filter { $0.hasPrefix("AX") }
  }

  private func getBounds(_ element: AXUIElement) -> CGRect? {
    var posValue: AnyObject?
    var sizeValue: AnyObject?

    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
          let pos = posValue,
          let size = sizeValue,
          CFGetTypeID(pos as CFTypeRef) == AXValueGetTypeID(),
          CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() else {
      return nil
    }

    var point = CGPoint.zero
    var sz = CGSize.zero
    guard AXValueGetValue(pos as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &sz) else {
      return nil
    }
    return CGRect(origin: point, size: sz)
  }

  private func ensureAppFrontmost(_ appName: String) throws {
    // Check if app is already frontmost
    if let frontmost = NSWorkspace.shared.frontmostApplication,
       let frontmostName = frontmost.localizedName,
       frontmostName.localizedCaseInsensitiveContains(appName) {
      return
    }

    // Resolve and focus the app
    guard let appPath = ApplicationManager.resolve(appName) else {
      throw ValidationError("Could not find application '\(appName)'")
    }

    let result = try ApplicationManager.openOrFocus(appPath)
    if result == .invalidPath {
      throw ValidationError("Invalid application path for '\(appName)'")
    }

    // Wait for activation
    usleep(100000)
  }
}
