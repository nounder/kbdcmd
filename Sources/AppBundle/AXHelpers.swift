import ApplicationServices
import Cocoa

/// Represents a clickable UI element found via accessibility API
struct ClickableElement: Identifiable {
  let id = UUID()
  let axElement: AXUIElement
  let frame: CGRect
  let title: String
  let role: String
  let isEnabled: Bool
}

/// Helper class for interacting with Accessibility API to collect clickable elements
class AXHelpers {

  /// Collects all visible clickable elements from the frontmost application window
  static func collectClickableElements() -> [ClickableElement] {
    var clickableElements: [ClickableElement] = []

    guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
      print("DEBUG: No frontmost app")
      return []
    }

    let axApp = AXUIElementCreateApplication(frontmostApp.processIdentifier)

    // Enhanced UI mode may help expose more web content in some browsers
    axApp.set(Ax.enhancedUserInterfaceAttr, true)

    guard let focusedWindow = axApp.get(Ax.focusedWindowAttr) else {
      return []
    }

    // Get window frame for visibility checking
    let windowFrame: CGRect?
    if let windowPosition = focusedWindow.get(Ax.topLeftCornerAttr),
      let windowSize = focusedWindow.get(Ax.sizeAttr)
    {
      // Convert window position from top-left origin to bottom-left origin for NSWindow
      let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
      let windowYBottomLeft = primaryScreenHeight - windowPosition.y - windowSize.height
      windowFrame = CGRect(
        x: windowPosition.x, y: windowYBottomLeft, width: windowSize.width,
        height: windowSize.height)
    } else {
      windowFrame = nil
    }

    // Support multiple monitors by checking all screen bounds
    let allScreenBounds = NSScreen.screens.map { $0.frame }

    var roleStats: [String: Int] = [:]
    var elementCount = 0

    // Recursively traverse accessibility tree starting from focused window
    collectElementsRecursively(
      from: focusedWindow,
      allScreenBounds: allScreenBounds,
      windowFrame: windowFrame,
      containerFrame: nil,
      roleStats: &roleStats,
      elementCount: &elementCount,
      clickableElements: &clickableElements,
      depth: 0
    )

    print("DEBUG: Collected \(clickableElements.count) elements")
    return clickableElements
  }

  /// Recursively traverses the accessibility tree to find clickable elements
  ///
  /// This function implements several important filtering rules:
  /// 1. Only processes elements within recursion depth limit
  /// 2. Tracks scroll containers (AXScrollArea, AXWebArea) to determine visibility
  /// 3. Filters out elements that are off-screen (multi-monitor aware)
  /// 4. Filters out elements scrolled outside their container's visible bounds
  private static func collectElementsRecursively(
    from element: AXUIElement,
    allScreenBounds: [CGRect],
    windowFrame: CGRect?,
    containerFrame: CGRect?,
    roleStats: inout [String: Int],
    elementCount: inout Int,
    clickableElements: inout [ClickableElement],
    depth: Int
  ) {
    // Prevent infinite recursion in malformed accessibility trees
    guard depth < 50 else { return }

    elementCount += 1

    // OPTIMIZATION: Check role first (cheapest attribute) before fetching others
    let role = element.get(Ax.roleAttr)
    guard let role = role else {
      // No role means we can skip this element entirely
      processChildren(
        of: element,
        allScreenBounds: allScreenBounds,
        windowFrame: windowFrame,
        containerFrame: containerFrame,
        roleStats: &roleStats,
        elementCount: &elementCount,
        clickableElements: &clickableElements,
        depth: depth
      )
      return
    }

    roleStats[role, default: 0] += 1

    // Only fetch position/size if this is a link, button, scroll container, or potentially a tab button
    let isLink = role == "AXLink"
    let isButton = role == "AXButton"
    let isRadioButton = role == "AXRadioButton"
    let isScrollContainer = role == "AXScrollArea" || role == "AXWebArea"

    // Check if this is a tab button (can have role AXButton or AXRadioButton)
    let isTab = isTabButton(element: element)

    // Debug logging for button detection
    if isButton {
      print("DEBUG: Found button element with role: \(role)")
    }
    if isTab {
      print("DEBUG: Found tab button with role: \(role)")
    }

    guard isLink || isButton || isTab || isScrollContainer else {
      // Skip fetching attributes for non-link, non-button, non-tab, non-container elements
      processChildren(
        of: element,
        allScreenBounds: allScreenBounds,
        windowFrame: windowFrame,
        containerFrame: containerFrame,
        roleStats: &roleStats,
        elementCount: &elementCount,
        clickableElements: &clickableElements,
        depth: depth
      )
      return
    }

    // OPTIMIZATION: Batch fetch common attributes for links, buttons, and scroll containers
    let attributes = getBatchAttributes(element: element)

    // Update container bounds when we encounter scroll areas
    // Nested containers are intersected to get the most restrictive visible bounds
    let currentContainerFrame = updateContainerFrame(
      existingContainer: containerFrame,
      element: element,
      role: role,
      position: attributes.position,
      size: attributes.size
    )

    // Check if this is a clickable link, button, or tab that should be displayed
    if isLink || isButton || isTab,
      let position = attributes.position,
      let size = attributes.size,
      isValidElementSize(size)
    {

      // Filter out window control buttons (close, minimize, full screen)
      // But always include tab buttons
      if isButton && !isTabButton(element: element) && isWindowControlButton(element: element) {
        print("DEBUG: Filtering out window control button")
        // Don't process children of window control buttons
        return
      }

      let frame = CGRect(x: position.x, y: position.y, width: size.width, height: size.height)
      let defaultTitle = isLink ? "Link" : (isTab ? "Tab" : "Button")
      let displayTitle = attributes.title ?? getElementDescription(element) ?? defaultTitle
      let trimmedTitle = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      let finalTitle = trimmedTitle.isEmpty ? defaultTitle : trimmedTitle

      // Debug logging for buttons and tabs
      if isButton || isTab {
        print(
          "DEBUG: Processing \(isTab ? "tab" : "button") '\(finalTitle)' at frame: \(frame), enabled: \(attributes.enabled ?? true)"
        )
        if let container = currentContainerFrame {
          print("DEBUG: Container frame: \(container)")
        } else {
          print("DEBUG: Container frame: nil")
        }
      }

      // Apply visibility filters
      if isElementVisible(
        frame: frame,
        screenBounds: allScreenBounds,
        windowFrame: windowFrame,
        containerFrame: currentContainerFrame,
        title: finalTitle)
      {

        if isButton || isTab {
          print("DEBUG: Adding \(isTab ? "tab" : "button") '\(finalTitle)' to clickable elements")
        }

        let clickable = ClickableElement(
          axElement: element,
          frame: frame,
          title: finalTitle,
          role: role,
          isEnabled: attributes.enabled ?? true
        )
        clickableElements.append(clickable)
      } else if isButton || isTab {
        print("DEBUG: \(isTab ? "Tab" : "Button") '\(finalTitle)' filtered out by visibility check")
      }
    } else if isButton || isTab {
      let positionStr = attributes.position.map { "\($0)" } ?? "nil"
      let sizeStr = attributes.size.map { "\($0)" } ?? "nil"
      print(
        "DEBUG: \(isTab ? "Tab" : "Button") filtered out - missing position/size or invalid size. position: \(positionStr), size: \(sizeStr)"
      )
    }

    // Recursively process all children
    processChildren(
      of: element,
      allScreenBounds: allScreenBounds,
      windowFrame: windowFrame,
      containerFrame: currentContainerFrame,
      roleStats: &roleStats,
      elementCount: &elementCount,
      clickableElements: &clickableElements,
      depth: depth
    )
  }

  // MARK: - Helper Methods

  /// Checks if an element is a tab button (should be included in clickable elements)
  private static func isTabButton(element: AXUIElement) -> Bool {
    // Check subrole attribute for AXTabButton
    if let subrole = element.get(Ax.subroleAttr), subrole == "AXTabButton" {
      return true
    }

    // Check Automation Type attribute (used by some applications)
    var automationType: AnyObject?
    if AXUIElementCopyAttributeValue(element, "AXAutomationType" as CFString, &automationType)
      == .success,
      let autoType = automationType as? String, autoType == "Tab"
    {
      return true
    }

    return false
  }

  /// Checks if an element is a window control button (close, minimize, full screen)
  /// These buttons should be excluded from clickable element selection
  private static func isWindowControlButton(element: AXUIElement) -> Bool {
    // Check subrole attribute (most reliable indicator)
    if let subrole = element.get(Ax.subroleAttr) {
      let windowControlSubroles = [
        "AXCloseButton",
        "AXMinimizeButton",
        "AXZoomButton",
      ]
      if windowControlSubroles.contains(subrole) {
        return true
      }
    }

    // Check description attribute for window control button keywords
    var description: AnyObject?
    if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &description)
      == .success,
      let desc = description as? String
    {
      let descLower = desc.lowercased()
      let windowControlKeywords = [
        "close button", "minimize button", "full screen button", "zoom button",
      ]
      if windowControlKeywords.contains(where: { descLower.contains($0) }) {
        return true
      }
    }

    // Check role description (sometimes shows "close button", "minimize button", etc.)
    var roleDescription: AnyObject?
    if AXUIElementCopyAttributeValue(
      element, kAXRoleDescriptionAttribute as CFString, &roleDescription) == .success,
      let roleDesc = roleDescription as? String
    {
      let roleDescLower = roleDesc.lowercased()
      let windowControlKeywords = [
        "close button", "minimize button", "full screen button", "zoom button",
      ]
      if windowControlKeywords.contains(where: { roleDescLower.contains($0) }) {
        return true
      }
    }

    return false
  }

  /// Lightweight struct for batch-fetched accessibility attributes
  /// Value type with zero runtime overhead compared to tuples
  private struct BatchAttributes {
    let position: CGPoint?
    let size: CGSize?
    let enabled: Bool?
    let title: String?

    /// Initializes with individual attribute values
    init(position: CGPoint?, size: CGSize?, enabled: Bool?, title: String?) {
      self.position = position
      self.size = size
      self.enabled = enabled
      self.title = title
    }
  }

  /// Batch fetches common attributes (position, size, enabled, title) in a single API call
  /// Returns a BatchAttributes struct (value type with zero runtime overhead)
  private static func getBatchAttributes(element: AXUIElement) -> BatchAttributes {
    // Define attributes to fetch in batch
    let attributes: [CFString] = [
      kAXPositionAttribute as CFString,
      kAXSizeAttribute as CFString,
      kAXEnabledAttribute as CFString,
      kAXTitleAttribute as CFString,
    ]

    var valuesArray: CFArray?
    let result = AXUIElementCopyMultipleAttributeValues(
      element,
      attributes as CFArray,
      [],
      &valuesArray
    )

    guard result == .success,
      let values = valuesArray as? [AnyObject],
      values.count == attributes.count
    else {
      // Fallback to individual calls if batch fails
      return BatchAttributes(
        position: element.get(Ax.topLeftCornerAttr),
        size: element.get(Ax.sizeAttr),
        enabled: element.get(Ax.enabledAttr),
        title: element.get(Ax.titleAttr)
      )
    }

    // Extract and convert values
    // Position (index 0) - stored as AXValue (CGPoint)
    var position: CGPoint? = nil
    if values.count > 0,
      CFGetTypeID(values[0]) == AXValueGetTypeID()
    {
      let axValue = values[0] as! AXValue
      var pos = CGPoint.zero
      if AXValueGetValue(axValue, .cgPoint, &pos) {
        position = pos
      }
    }

    // Size (index 1) - stored as AXValue (CGSize)
    var size: CGSize? = nil
    if values.count > 1,
      CFGetTypeID(values[1]) == AXValueGetTypeID()
    {
      let axValue = values[1] as! AXValue
      var sz = CGSize.zero
      if AXValueGetValue(axValue, .cgSize, &sz) {
        size = sz
      }
    }

    // Enabled (index 2) - stored as Bool
    let enabled = values.count > 2 ? values[2] as? Bool : nil

    // Title (index 3) - stored as String
    let title = values.count > 3 ? values[3] as? String : nil

    return BatchAttributes(position: position, size: size, enabled: enabled, title: title)
  }

  /// Updates the container frame when encountering scroll areas
  ///
  /// Solution 2 (current): Use container's position+size as visible viewport
  /// - Assumes position+size represents the visible viewport bounds
  /// - Filters elements that intersect with this viewport
  ///
  /// Alternative Solution 1: Get scroll offsets and calculate visible viewport
  /// - Could fetch kAXHorizontalScrollBar/kAXVerticalScrollBar attributes
  /// - Or track scroll position changes over time
  /// - Calculate visible bounds = container position + scroll offset to container position + size
  private static func updateContainerFrame(
    existingContainer: CGRect?,
    element: AXUIElement,
    role: String?,
    position: CGPoint?,
    size: CGSize?
  ) -> CGRect? {
    guard let position = position,
      let size = size,
      let role = role,
      role == "AXScrollArea" || role == "AXWebArea"
    else {
      return existingContainer
    }

    // For scroll containers, position + size should represent the VISIBLE viewport
    // However, if coordinates are document-relative (negative), we need to calculate
    // the visible viewport differently. Try to get scroll position if available.

    // Try to get scroll position (Solution 1 approach - not fully implemented)
    // Some browsers expose scroll position via scroll bar elements or other attributes
    // For now, we'll use position+size as visible viewport (Solution 2)

    let visibleViewport = CGRect(
      x: position.x, y: position.y, width: size.width, height: size.height)
    print("DEBUG: Found \(role) container - visible viewport: \(visibleViewport)")

    // If we already have a parent container, intersect to get visible area
    // This handles nested scroll areas correctly
    if let existingContainer = existingContainer {
      let intersection = existingContainer.intersection(visibleViewport)
      print("DEBUG: Intersected with existing container: \(intersection)")
      return intersection
    }

    return visibleViewport
  }

  /// Checks if element size is valid (positive width and height)
  private static func isValidElementSize(_ size: CGSize) -> Bool {
    return size.width > 0 && size.height > 0
  }

  /// Gets display title for an element, with fallback to "Link" if none found
  private static func getDisplayTitle(for element: AXUIElement) -> String {
    let title =
      element.get(Ax.titleAttr)
      ?? getElementDescription(element)
      ?? ""
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedTitle.isEmpty ? "Link" : trimmedTitle
  }

  /// Checks if element is visible based on screen bounds and scroll container viewports
  ///
  /// For web elements, coordinates are relative to the document content area, not screen.
  /// We check if elements intersect with:
  /// 1. Screen bounds (for native elements)
  /// 2. Scroll container's visible viewport (for web elements)
  ///
  /// - Parameters:
  ///   - frame: Element's frame (may be in screen or document coordinates)
  ///   - screenBounds: Array of all screen bounds
  ///   - windowFrame: Window frame in screen coordinates (for web content visibility)
  ///   - containerFrame: Optional container visible viewport bounds (for web areas)
  ///   - title: Element title (for debug logging)
  /// - Returns: true if element should be displayed
  private static func isElementVisible(
    frame: CGRect,
    screenBounds: [CGRect],
    windowFrame: CGRect?,
    containerFrame: CGRect?,
    title: String
  ) -> Bool {
    // First check: Is element on screen (for elements with screen coordinates)
    let isOnScreen = screenBounds.contains { $0.intersects(frame) }

    if isOnScreen {
      print("DEBUG: Including '\(title)' - element at \(frame) is on screen")
      return true
    }

    // Second check: For web elements, check if they intersect with the visible viewport
    if let containerViewport = containerFrame {
      // Element is inside a web/scroll container
      // The containerFrame represents the visible viewport of the scroll container
      // Check if the element intersects with this visible viewport
      let intersectsViewport = containerViewport.intersects(frame)

      if intersectsViewport {
        print(
          "DEBUG: Including '\(title)' - web element at \(frame) intersects visible viewport \(containerViewport)"
        )
        return true
      } else {
        print(
          "DEBUG: Filtering out '\(title)' - web element at \(frame) outside visible viewport \(containerViewport)"
        )
        return false
      }
    }

    // No container and not on screen = not visible
    print("DEBUG: Filtering out '\(title)' - off screen at \(frame)")
    return false
  }

  /// Processes all children of an element recursively
  private static func processChildren(
    of element: AXUIElement,
    allScreenBounds: [CGRect],
    windowFrame: CGRect?,
    containerFrame: CGRect?,
    roleStats: inout [String: Int],
    elementCount: inout Int,
    clickableElements: inout [ClickableElement],
    depth: Int
  ) {
    var children: AnyObject?
    guard
      AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        == .success,
      let childElements = children as? [AXUIElement]
    else {
      return
    }

    for child in childElements {
      collectElementsRecursively(
        from: child,
        allScreenBounds: allScreenBounds,
        windowFrame: windowFrame,
        containerFrame: containerFrame,
        roleStats: &roleStats,
        elementCount: &elementCount,
        clickableElements: &clickableElements,
        depth: depth + 1
      )
    }
  }

  /// Attempts to get a description for an element by checking various attributes
  /// Tries in order: description, value, role description, URL
  /// Uses batch attribute retrieval for better performance
  private static func getElementDescription(_ element: AXUIElement) -> String? {
    // Define attributes to fetch in priority order (as CFString)
    let attributes: [CFString] = [
      kAXDescriptionAttribute as CFString,
      kAXValueAttribute as CFString,
      kAXRoleDescriptionAttribute as CFString,
      kAXURLAttribute as CFString,
    ]

    // Fetch all attributes at once using batch API
    // The API returns a CFArray with values in the same order as the attributes array
    // Missing attributes are represented as NSNull or nil in the array
    var valuesArray: CFArray?
    let result = AXUIElementCopyMultipleAttributeValues(
      element,
      attributes as CFArray,
      [],
      &valuesArray
    )

    guard result == .success,
      let values = valuesArray as? [AnyObject]
    else {
      return nil
    }

    // Process attributes in priority order (values correspond to attributes by index)
    // Handle missing attributes gracefully - they may be NSNull or missing from array
    // 1. Try description attribute
    if values.count > 0,
      let desc = values[0] as? String, !desc.isEmpty
    {
      return desc
    }

    // 2. Try value (especially useful for text fields)
    if values.count > 1,
      let val = values[1] as? String, !val.isEmpty
    {
      return String(val.prefix(50))  // Limit length for display
    }

    // 3. Try role description
    if values.count > 2,
      let roleDesc = values[2] as? String, !roleDesc.isEmpty
    {
      return roleDesc
    }

    // 4. Try URL for links
    if values.count > 3,
      let urlValue = values[3] as? URL
    {
      return urlValue.absoluteString
    }

    return nil
  }

  /// Performs a click action on the given element
  static func clickElement(_ element: ClickableElement) -> Bool {
    let result = AXUIElementPerformAction(element.axElement, kAXPressAction as CFString)

    if result == .success {
      print("Successfully clicked: \(element.title)")
      return true
    } else {
      print("Failed to click element: \(element.title), error: \(result.rawValue)")
      return false
    }
  }
}
