@preconcurrency import ApplicationServices
import AppKit
import ArgumentParser
import Core
import Foundation

@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ axUiElement: AXUIElement, _ id: inout CGWindowID) -> AXError

struct WalkerCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "walker",
    abstract: "Walk the accessibility tree",
    discussion: """
      Traverses the accessibility tree of the frontmost window and outputs XML.

      Examples:
        kbdcmd walker                    # Walk focused window
        kbdcmd walker --max-depth 5      # Limit traversal to 5 levels deep
        kbdcmd walker --all-windows      # Walk entire app
        kbdcmd walker --title "My Doc"   # Walk window with matching title
        kbdcmd walker --pid 12345        # Walk window by process ID
      """
  )

  @Option(name: .long, help: "Maximum depth to traverse (unlimited if not specified)")
  var maxDepth: Int?

  @Option(name: .long, help: "Target window by CGWindowID (use window-list to find)")
  var cgid: Int?

  @Option(name: .long, help: "Filter by application name or bundle ID")
  var app: String?

  @Option(name: .long, help: "Filter by window title")
  var title: String?

  @Option(name: .long, help: "Filter by process ID")
  var pid: pid_t?

  @Flag(name: .long, help: "Include element IDs")
  var id: Bool = false

  @Flag(name: .long, help: "Include position and size information")
  var bounds: Bool = false

  @Flag(name: .long, help: "Use human-readable tag names")
  var roleTag: Bool = false

  @Flag(name: .long, help: "Traverse entire app instead of just focused window")
  var allWindows: Bool = false

  @Flag(name: .long, help: "Skip empty AXGroup elements")
  var noEmptyGroups: Bool = false

  @Flag(name: .long, help: "Hide description if same as title")
  var collapseTitle: Bool = false

  @Flag(name: .long, help: "Render AXStaticText as text nodes")
  var inlineText: Bool = false

  @Flag(name: .long, help: "Skip scroll bar elements")
  var noScrollbar: Bool = false

  @Flag(name: .long, help: "Include available actions")
  var action: Bool = false

  @Option(name: .long, help: "Include actions matching pattern (glob: 'AX*', list: 'AXPress,AXScroll')")
  var actionP: String?

  @Flag(name: .long, help: "Include action descriptions as values")
  var actionDesc: Bool = false

  @Flag(name: .long, help: "Only show elements with width and height > 5px")
  var visual: Bool = false

  @Flag(name: .long, help: "Hide title/description/value if empty or whitespace-only")
  var noEmpty: Bool = false

  @MainActor
  func run() async throws {
    try Permissions.checkAccessibility()

    let filterCount = [cgid != nil, app != nil, title != nil, pid != nil].filter { $0 }.count
    if filterCount > 1 {
      throw ValidationError("--cgid, --app, --title, and --pid are mutually exclusive")
    }

    if action && actionP != nil {
      throw ValidationError("--action and --action-p are mutually exclusive")
    }

    let actionMatcher: ((String) -> Bool)? = if let pattern = actionP {
      { self.matchesFilter($0, pattern: pattern) }
    } else if action {
      { _ in true }
    } else {
      nil
    }

    let root: AXUIElement

    if let cgid = cgid {
      guard let window = findWindowByCGID(CGWindowID(cgid)) else {
        throw ValidationError("No window found with cgid \(cgid)")
      }
      root = window
    } else if let app = app {
      guard let window = findWindowByApp(app) else {
        throw ValidationError("No window found for app '\(app)'")
      }
      root = window
    } else if let title = title {
      guard let window = findWindowByTitle(title) else {
        throw ValidationError("No window found with title '\(title)'")
      }
      root = window
    } else if let pid = pid {
      guard let window = findWindowByPid(pid) else {
        throw ValidationError("No window found for pid \(pid)")
      }
      root = window
    } else if allWindows {
      guard let app = NSWorkspace.shared.frontmostApplication else {
        throw ValidationError("No frontmost application found")
      }
      root = AXUIElementCreateApplication(app.processIdentifier)
    } else {
      guard let app = NSWorkspace.shared.frontmostApplication else {
        throw ValidationError("No frontmost application found")
      }
      let appElement = AXUIElementCreateApplication(app.processIdentifier)
      var focusedWindow: AnyObject?
      guard AXUIElementCopyAttributeValue(
        appElement,
        kAXFocusedWindowAttribute as CFString,
        &focusedWindow
      ) == .success,
            let window = focusedWindow,
            CFGetTypeID(window as CFTypeRef) == AXUIElementGetTypeID()
      else {
        throw ValidationError("No focused window found")
      }
      root = window as! AXUIElement
    }

    var openTags: [(role: String, depth: Int)] = []
    var stack: [(element: AXUIElement, depth: Int, parentId: String?, siblingIndex: Int)] = [
      (root, 0, nil, 0)
    ]

    while let (element, depth, parentId, siblingIndex) = stack.popLast() {
      if let maxDepth = maxDepth, depth > maxDepth {
        continue
      }

      while let last = openTags.last, last.depth >= depth {
        openTags.removeLast()
        print("\(String(repeating: "  ", count: last.depth))</\(last.role)>")
      }

      let nodeId = parentId.map { "\($0)-\(siblingIndex)" } ?? "#0"
      let rawRole = getAttr(element, kAXRoleAttribute) as? String ?? "Unknown"
      let title = (getAttr(element, kAXTitleAttribute) as? String).map { escapeAttribute($0) }
      let children = getChildren(element)
      let hasChildren = !children.isEmpty && (maxDepth == nil || depth < maxDepth!)

      // Skip empty groups and zero-size elements (unless they have actions)
      if noEmptyGroups {
        if rawRole == "AXGroup" && children.isEmpty {
          continue
        }
        if let b = getBounds(element), b.width == 0 || b.height == 0 {
          if getActions(element).isEmpty {
            continue
          }
        }
      }

      // Skip scrollbar elements
      if noScrollbar && rawRole == "AXScrollBar" {
        continue
      }

      // Skip elements smaller than 5px
      if visual {
        if let b = getBounds(element) {
          if b.width <= 5 || b.height <= 5 {
            continue
          }
        } else {
          continue
        }
      }

      let value = (getAttr(element, kAXValueAttribute) as? String).map { escapeAttribute($0) }
      let description = (getAttr(element, kAXDescriptionAttribute) as? String).map { escapeAttribute($0) }
      let rawRoleDescription = getAttr(element, kAXRoleDescriptionAttribute) as? String
      let label = (getAttr(element, "AXLabel") as? String).map { escapeAttribute($0) }

      let role: String
      let showRoleDescription: Bool
      if roleTag, let customTag = tagMap[rawRole] {
        role = customTag
        showRoleDescription = false
      } else if roleTag, let rd = rawRoleDescription, !rd.isEmpty, rd.lowercased() != "unknown" {
        role = escapeAttribute(hyphenize(rd))
        showRoleDescription = false
      } else {
        // If rawRole is "Unknown" and we have --role-tag, show the AX role for debugging
        if roleTag && rawRole == "Unknown" {
          role = "AXUnknown"
        } else {
          role = escapeAttribute(rawRole)
        }
        showRoleDescription = rawRoleDescription != nil && !rawRoleDescription!.isEmpty && rawRoleDescription!.lowercased() != "unknown"
      }

      let indent = String(repeating: "  ", count: depth)
      var attrs = ""
      if id {
        attrs += "id=\"\(escapeAttribute(nodeId))\""
      }
      if bounds, let b = getBounds(element) {
        if !attrs.isEmpty { attrs += " " }
        attrs += "bounds=\"\(Int(b.origin.x)),\(Int(b.origin.y)),\(Int(b.width)),\(Int(b.height))\""
      }
      if let title = title, hasContent(title) {
        if !attrs.isEmpty { attrs += " " }
        attrs += "title=\"\(truncate(title))\""
      }
      if let value = value, hasContent(value) {
        if !attrs.isEmpty { attrs += " " }
        attrs += "value=\"\(truncate(value))\""
      }
      let showDescription = description != nil && hasContent(description!) && !(collapseTitle && description == title)
      if showDescription {
        if !attrs.isEmpty { attrs += " " }
        attrs += "description=\"\(truncate(description!))\""
      }
      if showRoleDescription, let rd = rawRoleDescription {
        if !attrs.isEmpty { attrs += " " }
        attrs += "roleDescription=\"\(truncate(escapeAttribute(rd)))\""
      }
      if let label = label, !label.isEmpty {
        if !attrs.isEmpty { attrs += " " }
        attrs += "label=\"\(truncate(label))\""
      }
      if let actionMatcher = actionMatcher {
        let actionNames = getActions(element).filter(actionMatcher)
        for actionName in actionNames {
          if !attrs.isEmpty { attrs += " " }
          if actionDesc, let desc = getActionDescription(element, actionName), !desc.isEmpty {
            attrs += "action:\(actionName)=\"\(escapeAttribute(desc))\""
          } else {
            attrs += "action:\(actionName)"
          }
        }
      }

      // Handle AXStaticText as text node when --text is set
      if inlineText && rawRole == "AXStaticText" {
        let textContent = (getAttr(element, kAXValueAttribute) as? String) ?? (getAttr(element, kAXTitleAttribute) as? String) ?? ""
        if !textContent.isEmpty {
          print("\(indent)\(escapeAttribute(textContent))")
        }
      } else {
        let attrStr = attrs.isEmpty ? "" : " \(attrs)"
        if hasChildren {
          print("\(indent)<\(role)\(attrStr)>")
          openTags.append((role: role, depth: depth))
        } else {
          print("\(indent)<\(role)\(attrStr) />")
        }
      }

      for (index, child) in children.enumerated().reversed() {
        stack.append((child, depth + 1, nodeId, index))
      }
    }

    while let last = openTags.popLast() {
      print("\(String(repeating: "  ", count: last.depth))</\(last.role)>")
    }
  }

  private func findWindowByApp(_ appFilter: String) -> AXUIElement? {
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

        return axWindow
      }
    }
    return nil
  }

  private func findWindowByCGID(_ targetCGID: CGWindowID) -> AXUIElement? {
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
        if _AXUIElementGetWindow(window, &cgWindowId) == .success && cgWindowId == targetCGID {
          return window
        }
      }
    }
    return nil
  }

  private func findWindowByTitle(_ titleFilter: String) -> AXUIElement? {
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
          return axWindow
        }
      }
    }
    return nil
  }

  private func findWindowByPid(_ pidFilter: pid_t) -> AXUIElement? {
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

      return axWindow
    }
    return nil
  }

  private func getAttr(_ element: AXUIElement, _ attr: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  private func getChildren(_ element: AXUIElement) -> [AXUIElement] {
    (getAttr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
  }

  private func getActions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success,
          let actionNames = names as? [String] else {
      return []
    }
    // Some apps (e.g. Apple TV) return malformed action names like:
    // "AXPress Name:More Target:0x0 Selector:(null)"
    // or separate entries like "Name:More\nTarget:0x0\nSelector:(null)"
    // Filter to only valid AX action names
    return actionNames
      .compactMap { $0.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) }
      .filter { $0.hasPrefix("AX") }
  }

  private func getActionDescription(_ element: AXUIElement, _ action: String) -> String? {
    var desc: CFString?
    guard AXUIElementCopyActionDescription(element, action as CFString, &desc) == .success,
          let description = desc as String? else {
      return nil
    }
    return description
  }

  private func getBounds(_ element: AXUIElement) -> CGRect? {
    guard let pos = getAttr(element, kAXPositionAttribute),
          let size = getAttr(element, kAXSizeAttribute),
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

  /// Escapes a string for use in HTML5-like output.
  ///
  /// Only escapes characters that would break parsing:
  /// - `<` → `&lt;` (would start a tag)
  /// - `"` → `&quot;` (would end an attribute value)
  ///
  /// Unlike strict XML, we don't escape:
  /// - `&` (kept as-is for readability, e.g., "Foo & Bar")
  /// - `>` (safe outside of tags)
  private func escapeAttribute(_ string: String) -> String {
    var result = ""
    result.reserveCapacity(string.count)
    for char in string {
      switch char {
      case "<": result += "&lt;"
      case "\"": result += "&quot;"
      default: result.append(char)
      }
    }
    return result
  }

  private func truncate(_ string: String, max: Int = 100) -> String {
    string.count > max ? String(string.prefix(max)) + "..." : string
  }

  private func hasContent(_ string: String) -> Bool {
    noEmpty ? !string.trimmingCharacters(in: .whitespaces).isEmpty : !string.isEmpty
  }

  private func hyphenize(_ string: String) -> String {
    string.replacingOccurrences(of: " ", with: "-")
  }

  private var tagMap: [String: String] {
    [
      "AXWindow": "window",
    ]
  }

  private func matchesFilter(_ input: String, pattern: String) -> Bool {
    let patterns = pattern.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

    return patterns.contains { p in
      if p.contains("*") || p.contains("?") {
        return fnmatch(p, input, 0) == 0
      } else {
        return input == p
      }
    }
  }
}
