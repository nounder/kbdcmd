@preconcurrency import ApplicationServices
import AppKit
import ArgumentParser
import Core
import Foundation

@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ axUiElement: AXUIElement, _ id: inout CGWindowID) -> AXError

private final class AXRegistry {
  private var actionsCache: [ObjectIdentifier: [String]] = [:]
  private var boundsCache: [ObjectIdentifier: CGRect?] = [:]
  private var childrenCache: [ObjectIdentifier: [AXUIElement]] = [:]
  private var attrCache: [ObjectIdentifier: [String: AnyObject?]] = [:]

  func getActions(_ element: AXUIElement) -> [String] {
    let key = ObjectIdentifier(element)
    if let cached = actionsCache[key] {
      return cached
    }
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success,
          let actionNames = names as? [String] else {
      actionsCache[key] = []
      return []
    }
    let result = actionNames
      .compactMap { $0.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) }
      .filter { $0.hasPrefix("AX") }
    actionsCache[key] = result
    return result
  }

  func getBounds(_ element: AXUIElement) -> CGRect? {
    let key = ObjectIdentifier(element)
    if let cached = boundsCache[key] {
      return cached
    }
    let result = computeBounds(element)
    boundsCache[key] = result
    return result
  }

  private func computeBounds(_ element: AXUIElement) -> CGRect? {
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

  func getChildren(_ element: AXUIElement, visibleOnly: Bool) -> [AXUIElement] {
    let key = ObjectIdentifier(element)
    if let cached = childrenCache[key] {
      return cached
    }
    let attr = visibleOnly ? kAXVisibleChildrenAttribute : kAXChildrenAttribute
    var result = (getAttr(element, attr) as? [AXUIElement]) ?? []
    // Fallback to all children if visible children returns empty
    if visibleOnly && result.isEmpty {
      result = (getAttr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
    childrenCache[key] = result
    return result
  }

  func getAttr(_ element: AXUIElement, _ attr: String) -> AnyObject? {
    let key = ObjectIdentifier(element)
    if let elementCache = attrCache[key], elementCache.keys.contains(attr) {
      return elementCache[attr] ?? nil
    }
    var value: AnyObject?
    let success = AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success
    if attrCache[key] == nil {
      attrCache[key] = [:]
    }
    attrCache[key]![attr] = success ? value : nil
    return success ? value : nil
  }
}

private struct WalkerNode {
  let role: String
  let rawRole: String
  let depth: Int
  let nodeId: String
  let title: String?
  let value: String?
  let description: String?
  let roleDescription: String?
  let label: String?
  let bounds: CGRect?
  let actions: [String]
  let hasChildren: Bool
  let selected: Bool
}

enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
  case indent
  case xml
}

struct TreeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tree",
    abstract: "Walk the accessibility tree",
    discussion: """
      Traverses the accessibility tree of the frontmost window and outputs it.

      Examples:
        kbdcmd tree                    # Walk focused window (indent format)
        kbdcmd tree --format xml       # Walk focused window (XML format)
        kbdcmd tree --max-depth 5      # Limit traversal to 5 levels deep
        kbdcmd tree --all-windows      # Walk entire app
        kbdcmd tree --title "My Doc"   # Walk window with matching title
        kbdcmd tree --pid 12345        # Walk window by process ID
      """
  )

  @Option(name: .long, help: "Output format: indent (default) or xml")
  var format: OutputFormat = .indent

  @Option(name: .long, help: "Maximum depth to traverse (unlimited if not specified)")
  var maxDepth: Int?

  @Option(name: .long, help: "Target window by CGWindowID (use window-list to find)")
  var cgid: Int?

  @Option(name: .shortAndLong, help: "Filter by application name or bundle ID")
  var app: String?

  @Option(name: .long, help: "Filter by window title")
  var title: String?

  @Option(name: .long, help: "Filter by process ID")
  var pid: pid_t?

  @Flag(name: .long, help: "Include element IDs")
  var id: Bool = false

  @Flag(inversion: .prefixedNo, help: "Include position and size information (default: on)")
  var bounds: Bool = true

  @Flag(name: .customLong("role-tag"), inversion: .prefixedNo, help: "Use human-readable tag names (default: on)")
  var roleTag: Bool = true

  @Flag(name: .long, help: "Traverse entire app instead of just focused window")
  var allWindows: Bool = false

  @Flag(name: .customLong("collapse-title"), inversion: .prefixedNo, help: "Hide description if same as title (default: on)")
  var collapseTitle: Bool = true

  @Flag(name: .customLong("inline-text"), inversion: .prefixedNo, help: "Render AXStaticText as quoted text nodes, concatenating consecutive text at same depth (default: on)")
  var inlineText: Bool = true

  @Flag(name: .customLong("scrollbar"), inversion: .prefixedNo, help: "Include scroll bar elements (default: off)")
  var scrollbar: Bool = false

  @Flag(inversion: .prefixedNo, help: "Include available actions (default: on)")
  var action: Bool = true

  @Option(name: .long, help: "Include actions matching pattern (glob: 'AX*', list: 'AXPress,AXScroll'). Default: 'AXPress,AXConfirm'")
  var actionP: String = "AXPress,AXConfirm"

  @Flag(name: .long, help: "Include action descriptions as values")
  var actionDesc: Bool = false

  @Flag(name: .customLong("tiny"), inversion: .prefixedNo, help: "Include tiny elements (width/height <= 5px) (default: off)")
  var tiny: Bool = false

  @Flag(name: .customLong("empty"), inversion: .prefixedNo, help: "Include empty groups and elements without text/attributes/actions (default: off)")
  var empty: Bool = false

  @Flag(name: .shortAndLong, help: "Show all elements without filtering (enables --scrollbar --tiny --empty --invisible)")
  var verbose: Bool = false

  @Flag(name: .long, help: "Include invisible/offscreen children (default: visible only)")
  var invisible: Bool = false

  @MainActor
  func run() async throws {
    try Permissions.checkAccessibility()

    let filterCount = [cgid != nil, app != nil, title != nil, pid != nil].filter { $0 }.count
    if filterCount > 1 {
      throw ValidationError("--cgid, --app, --title, and --pid are mutually exclusive")
    }

    let actionMatcher: ((String) -> Bool)? = if action {
      { self.matchesFilter($0, pattern: self.actionP) }
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

    let registry = AXRegistry()
    let nodes = traverse(root: root, registry: registry, actionMatcher: actionMatcher)

    switch format {
    case .indent:
      printIndentFormat(nodes: nodes, actionMatcher: actionMatcher)
    case .xml:
      printXmlFormat(nodes: nodes, actionMatcher: actionMatcher)
    }
  }

  private func traverse(
    root: AXUIElement,
    registry: AXRegistry,
    actionMatcher: ((String) -> Bool)?
  ) -> [WalkerNode] {
    let includeScrollbar = verbose || scrollbar
    let includeTiny = verbose || tiny
    let includeEmpty = verbose || empty
    let visibleOnly = !(verbose || invisible)

    func buildNode(
      element: AXUIElement,
      depth: Int,
      nodeId: String
    ) -> (node: WalkerNode, hasMeaningfulContent: Bool)? {
      if let maxDepth = maxDepth, depth > maxDepth {
        return nil
      }

      let rawRole = registry.getAttr(element, kAXRoleAttribute) as? String ?? "Unknown"

      if !includeScrollbar && rawRole == "AXScrollBar" {
        return nil
      }

      if !includeTiny {
        if let b = registry.getBounds(element) {
          if b.width <= 5 || b.height <= 5 {
            return nil
          }
        } else {
          return nil
        }
      }

      let children = registry.getChildren(element, visibleOnly: visibleOnly)
      let hasChildren = !children.isEmpty && (maxDepth == nil || depth < maxDepth!)

      let title = registry.getAttr(element, kAXTitleAttribute) as? String
      let value = registry.getAttr(element, kAXValueAttribute) as? String
      let description = registry.getAttr(element, kAXDescriptionAttribute) as? String
      let rawRoleDescription = registry.getAttr(element, kAXRoleDescriptionAttribute) as? String
      let label = registry.getAttr(element, "AXLabel") as? String
      let elementBounds = bounds ? registry.getBounds(element) : nil
      let selected = (registry.getAttr(element, kAXSelectedAttribute) as? Bool) ?? false

      let role: String
      let showRoleDescription: Bool
      if roleTag, let customTag = tagMap[rawRole] {
        role = customTag
        showRoleDescription = false
      } else if roleTag, let rd = rawRoleDescription, !rd.isEmpty, rd.lowercased() != "unknown" {
        role = simplifyRole(hyphenize(rd))
        showRoleDescription = false
      } else {
        if roleTag && rawRole == "Unknown" {
          role = "AXUnknown"
        } else {
          role = rawRole
        }
        showRoleDescription = rawRoleDescription != nil && !rawRoleDescription!.isEmpty && rawRoleDescription!.lowercased() != "unknown"
      }

      let actions: [String]
      if let actionMatcher = actionMatcher {
        actions = registry.getActions(element).filter(actionMatcher)
      } else {
        actions = []
      }

      let hasTitle = title.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
      let hasValue = value.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
      let hasDesc = description.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
      let hasLabel = label.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
      let hasRoleDesc = showRoleDescription
      let hasActions = !actions.isEmpty

      let hasMeaningfulContent = hasTitle || hasValue || hasDesc || hasLabel || hasRoleDesc || hasActions

      let node = WalkerNode(
        role: role,
        rawRole: rawRole,
        depth: depth,
        nodeId: nodeId,
        title: title,
        value: value,
        description: description,
        roleDescription: showRoleDescription ? rawRoleDescription : nil,
        label: label,
        bounds: elementBounds,
        actions: actions,
        hasChildren: hasChildren,
        selected: selected
      )

      return (node, hasMeaningfulContent)
    }

    func traverseRecursive(
      element: AXUIElement,
      depth: Int,
      nodeId: String
    ) -> (nodes: [WalkerNode], hasMeaningfulDescendant: Bool) {
      guard let (node, hasMeaningfulContent) = buildNode(element: element, depth: depth, nodeId: nodeId) else {
        return ([], false)
      }

      let children = registry.getChildren(element, visibleOnly: visibleOnly)
      var childNodes: [WalkerNode] = []
      var anyChildHasMeaningful = false

      for (index, child) in children.enumerated() {
        let childId = "\(nodeId)-\(index)"
        let (descendantNodes, hasMeaningful) = traverseRecursive(element: child, depth: depth + 1, nodeId: childId)
        childNodes.append(contentsOf: descendantNodes)
        if hasMeaningful {
          anyChildHasMeaningful = true
        }
      }

      let shouldInclude = includeEmpty || hasMeaningfulContent || anyChildHasMeaningful

      if shouldInclude {
        return ([node] + childNodes, hasMeaningfulContent || anyChildHasMeaningful)
      } else {
        return ([], false)
      }
    }

    let (nodes, _) = traverseRecursive(element: root, depth: 0, nodeId: "#0")
    return nodes
  }

  private func printIndentFormat(nodes: [WalkerNode], actionMatcher: ((String) -> Bool)?) {
    var pendingTexts: [String] = []
    var pendingDepth: Int = 0

    func flushPendingTexts() {
      if !pendingTexts.isEmpty {
        let indent = String(repeating: "  ", count: pendingDepth)
        print("\(indent)\"\(pendingTexts.joined(separator: " "))\"")
        pendingTexts.removeAll()
      }
    }

    for node in nodes {
      if inlineText && node.rawRole == "AXStaticText" && node.actions.isEmpty {
        let textContent = node.value ?? node.title ?? ""
        if !textContent.isEmpty {
          if pendingTexts.isEmpty {
            pendingDepth = node.depth
            pendingTexts.append(textContent)
          } else if node.depth == pendingDepth {
            pendingTexts.append(textContent)
          } else {
            flushPendingTexts()
            pendingDepth = node.depth
            pendingTexts.append(textContent)
          }
        }
        continue
      }

      flushPendingTexts()

      let indent = String(repeating: "  ", count: node.depth)
      var parts: [String] = [node.role.uppercased()]

      // Determine text part and remaining attributes
      // Priority: title, then value -> description -> label for text part
      let title = node.title.flatMap { hasContent($0) ? $0 : nil }
      let value = node.value.flatMap { hasContent($0) ? $0 : nil }
      let description = node.description.flatMap { hasContent($0) ? $0 : nil }
      let label = node.label.flatMap { hasContent($0) ? $0 : nil }

      var textPart: String? = nil
      var showValue = false
      var showDescription = false
      var showLabel = false

      if let t = title {
        // Title is always the text part if present
        textPart = t
        // Show other attrs only if different from title
        showValue = value != nil && value != t
        showDescription = description != nil && description != t && !(collapseTitle && description == t)
        showLabel = label != nil && label != t
      } else {
        // No title - collapse value/description/label
        // Pick first non-nil as text part, show others only if different
        if let v = value {
          textPart = v
          showDescription = description != nil && description != v
          showLabel = label != nil && label != v
        } else if let d = description {
          textPart = d
          showLabel = label != nil && label != d
        } else if let l = label {
          textPart = l
        }
      }

      if let text = textPart {
        parts.append("\"\(truncate(text))\"")
      }

      if showValue, let v = value {
        parts.append("value=\"\(truncate(v))\"")
      }

      if showDescription, let d = description {
        parts.append("description=\"\(truncate(d))\"")
      }

      if let rd = node.roleDescription {
        parts.append("roleDescription=\"\(truncate(rd))\"")
      }

      if showLabel, let l = label {
        parts.append("label=\"\(truncate(l))\"")
      }

      if id {
        parts.append("id=\"\(node.nodeId)\"")
      }

      if node.selected {
        parts.append("selected=true")
      }

      // Actions as attributes (e.g., on:AXPress)
      for action in node.actions {
        parts.append("on:\(action)")
      }

      if let b = node.bounds {
        parts.append("@\(Int(b.origin.x)),\(Int(b.origin.y)),\(Int(b.width)),\(Int(b.height))")
      }

      print("\(indent)\(parts.joined(separator: " "))")
    }

    flushPendingTexts()
  }

  private func printXmlFormat(nodes: [WalkerNode], actionMatcher: ((String) -> Bool)?) {
    var openTags: [(role: String, depth: Int)] = []

    for node in nodes {
      while let last = openTags.last, last.depth >= node.depth {
        openTags.removeLast()
        print("\(String(repeating: "  ", count: last.depth))</\(escapeAttribute(last.role))>")
      }

      let indent = String(repeating: "  ", count: node.depth)

      if inlineText && node.rawRole == "AXStaticText" && node.actions.isEmpty {
        let textContent = node.value ?? node.title ?? ""
        if !textContent.isEmpty {
          print("\(indent)\(escapeAttribute(textContent))")
        }
        continue
      }

      var attrs = ""
      if id {
        attrs += "id=\"\(escapeAttribute(node.nodeId))\""
      }
      if let b = node.bounds {
        if !attrs.isEmpty { attrs += " " }
        attrs += "bounds=\"\(Int(b.origin.x)),\(Int(b.origin.y)),\(Int(b.width)),\(Int(b.height))\""
      }
      if let title = node.title, hasContent(title) {
        if !attrs.isEmpty { attrs += " " }
        attrs += "title=\"\(truncate(escapeAttribute(title)))\""
      }
      if let value = node.value, hasContent(value) {
        if !attrs.isEmpty { attrs += " " }
        attrs += "value=\"\(truncate(escapeAttribute(value)))\""
      }
      let showDescription = node.description != nil && hasContent(node.description!) && !(collapseTitle && node.description == node.title)
      if showDescription {
        if !attrs.isEmpty { attrs += " " }
        attrs += "description=\"\(truncate(escapeAttribute(node.description!)))\""
      }
      if let rd = node.roleDescription {
        if !attrs.isEmpty { attrs += " " }
        attrs += "roleDescription=\"\(truncate(escapeAttribute(rd)))\""
      }
      if let label = node.label, !label.isEmpty {
        if !attrs.isEmpty { attrs += " " }
        attrs += "label=\"\(truncate(escapeAttribute(label)))\""
      }
      if node.selected {
        if !attrs.isEmpty { attrs += " " }
        attrs += "selected=true"
      }
      for actionName in node.actions {
        if !attrs.isEmpty { attrs += " " }
        attrs += "action:\(actionName)"
      }

      let role = escapeAttribute(node.role)
      let attrStr = attrs.isEmpty ? "" : " \(attrs)"
      if node.hasChildren {
        print("\(indent)<\(role)\(attrStr)>")
        openTags.append((role: node.role, depth: node.depth))
      } else {
        print("\(indent)<\(role)\(attrStr) />")
      }
    }

    while let last = openTags.popLast() {
      print("\(String(repeating: "  ", count: last.depth))</\(escapeAttribute(last.role))>")
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

  private func getActionDescription(_ element: AXUIElement, _ action: String) -> String? {
    var desc: CFString?
    guard AXUIElementCopyActionDescription(element, action as CFString, &desc) == .success,
          let description = desc as String? else {
      return nil
    }
    return description
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
    !empty ? !string.trimmingCharacters(in: .whitespaces).isEmpty : !string.isEmpty
  }

  private func hyphenize(_ string: String) -> String {
    string.replacingOccurrences(of: " ", with: "-")
  }

  private func simplifyRole(_ role: String) -> String {
    let lowercased = role.lowercased()
    switch lowercased {
    case "outline-row", "table-row":
      return "row"
    case "toggle-button":
      return "button"
    default:
      return role
    }
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
