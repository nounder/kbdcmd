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
  let actions: [String]
}

/// Stateful interface for traversing accessibility tree with context tracking
class AXInterface {
  private let root: AXUIElement
  private var currentHierarchy: [AXUIElement] = []
  private var scrollAreas: [CGRect] = []
  private var chromeAreas: [CGRect] = []
  private var isInScrollBar = false

  // Computed properties for accessing current context
  private var currentScrollArea: CGRect? { scrollAreas.last }
  private var currentChromeArea: CGRect? { chromeAreas.last }
  private var currentIsInChrome: Bool { !chromeAreas.isEmpty }

  // Element type for tracking during traversal
  enum ElementType {
    case chrome
    case scrollContainer
    case scrollBar
    case regular
  }

  init(root: AXUIElement) {
    self.root = root
  }

  /// Collects all visible clickable elements from the window
  func collectClickableElements() -> [ClickableElement] {
    var clickableElements: [ClickableElement] = []
    var roleStats: [String: Int] = [:]
    var elementCount = 0

    // Support multiple monitors by checking all screen bounds
    let allScreenBounds = NSScreen.screens.map { $0.frame }

    // Get window frame for visibility checking
    let windowFrame: CGRect?
    if let windowPosition = root.get(Ax.topLeftCornerAttr),
      let windowSize = root.get(Ax.sizeAttr)
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

    // Traverse accessibility tree starting from window root
    traverseElement(
      root,
      allScreenBounds: allScreenBounds,
      windowFrame: windowFrame,
      roleStats: &roleStats,
      elementCount: &elementCount,
      clickableElements: &clickableElements,
      depth: 0
    )

    debugLog("Collected \(clickableElements.count) elements")
    return clickableElements
  }

  /// Enters an element during traversal, updating context state
  /// Returns the element type so exitElement knows which stacks to pop
  private func enterElement(
    _ element: AXUIElement,
    _ role: String?,
    _ position: CGPoint?,
    _ size: CGSize?
  ) -> ElementType {
    // Always push to hierarchy
    currentHierarchy.append(element)

    // Check if this is a scroll bar element
    if let role = role, role == "AXScrollBar" {
      isInScrollBar = true
      debugLog("Entered scroll bar element")
      return .scrollBar
    }

    // Check if this is a chrome element
    if let role = role, isChrome(element, role) {
      if let position = position, let size = size {
        let chromeBounds = CGRect(
          x: position.x, y: position.y, width: size.width, height: size.height)
        chromeAreas.append(chromeBounds)
        debugLog("Entered chrome element with role: \(role), bounds: \(chromeBounds)")
      }
      return .chrome
    }

    // Check if this is a scroll container
    if let role = role,
      let scrollViewport = getScrollContainerViewport(element, role, position, size)
    {
      scrollAreas.append(scrollViewport)
      debugLog("Entered scroll container with role: \(role), viewport: \(scrollViewport)")
      return .scrollContainer
    }

    return .regular
  }

  /// Exits an element during traversal, popping from appropriate stacks
  private func exitElement(_ type: ElementType) {
    // Always pop from hierarchy
    if !currentHierarchy.isEmpty {
      currentHierarchy.removeLast()
    }

    // Pop from specific stacks based on element type
    switch type {
    case .scrollBar:
      isInScrollBar = false
    case .chrome:
      if !chromeAreas.isEmpty {
        chromeAreas.removeLast()
      }
    case .scrollContainer:
      if !scrollAreas.isEmpty {
        scrollAreas.removeLast()
      }
    case .regular:
      break
    }
  }

  /// Checks if an element is window chrome (toolbar, title bar, window controls)
  private func isChrome(_ element: AXUIElement, _ role: String) -> Bool {
    // Check for toolbar role
    if role == "AXToolbar" {
      return true
    }

    // Check for toolbar subrole
    if let subrole = element.get(Ax.subroleAttr) {
      if subrole == "AXToolbar" {
        return true
      }
    }

    // Check if this is a window control button
    if role == "AXButton" {
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
    }

    return false
  }

  /// Gets the visible viewport bounds for a scroll container, if applicable
  private func getScrollContainerViewport(
    _ element: AXUIElement,
    _ role: String,
    _ position: CGPoint?,
    _ size: CGSize?
  ) -> CGRect? {
    guard role == "AXScrollArea" || role == "AXWebArea" else {
      return nil
    }

    guard let position = position, let size = size else {
      return nil
    }

    let viewport = CGRect(x: position.x, y: position.y, width: size.width, height: size.height)

    // If we already have a parent scroll container, intersect to get the visible area
    if let parentViewport = currentScrollArea {
      return parentViewport.intersection(viewport)
    }

    return viewport
  }

  /// Recursively traverses the accessibility tree to find clickable elements
  ///
  /// Uses context tracking to filter elements based on:
  /// 1. Chrome context (toolbars, window controls)
  /// 2. Scroll container visibility (50% threshold)
  /// 3. Screen bounds (multi-monitor aware)
  private func traverseElement(
    _ element: AXUIElement,
    allScreenBounds: [CGRect],
    windowFrame: CGRect?,
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

    // Track role stats
    if let role = role {
      roleStats[role, default: 0] += 1
    }

    // OPTIMIZATION: Batch fetch common attributes for links, buttons, and scroll containers
    let attributes = getBatchAttributes(element: element)

    // Enter element context - this updates our state stacks
    let elementType = enterElement(element, role, attributes.position, attributes.size)

    // Defer exit to ensure we always pop from stacks
    defer {
      exitElement(elementType)
    }

    // If we're in chrome, skip processing this element's clickability
    // but still traverse children in case there's content below
    guard !currentIsInChrome else {
      processChildren(
        of: element,
        allScreenBounds: allScreenBounds,
        windowFrame: windowFrame,
        roleStats: &roleStats,
        elementCount: &elementCount,
        clickableElements: &clickableElements,
        depth: depth
      )
      return
    }

    // If we're in a scroll bar, skip processing this element's clickability
    // but still traverse children
    guard !isInScrollBar else {
      processChildren(
        of: element,
        allScreenBounds: allScreenBounds,
        windowFrame: windowFrame,
        roleStats: &roleStats,
        elementCount: &elementCount,
        clickableElements: &clickableElements,
        depth: depth
      )
      return
    }

    // Check if this is a clickable element type
    let isLink = role == "AXLink"
    let isButton = role == "AXButton"
    let isRadioButton = role == "AXRadioButton"
    let isTab = isTabButton(element: element)
    let isTextField = role == "AXTextField"
    let isCheckBox = role == "AXCheckBox"
    let isTextArea = role == "AXTextArea"
    let isPopUpButton = role == "AXPopUpButton"
    let isMenuItem = role == "AXMenuItem"
    let isActionable = hasAction(element: element)
    // Check for AXGroup elements that have AXPress action (e.g., toolbar buttons in rich text editors)
    let isClickableGroup = role == "AXGroup" && isActionable

    // Debug logging for button detection
    if isButton {
      debugLog("Found button element with role: \(role ?? "nil")")
    }
    if isTab {
      debugLog("Found tab button with role: \(role ?? "nil")")
    }
    if isTextField {
      debugLog("Found text field element with role: \(role ?? "nil")")
    }
    if isCheckBox {
      debugLog("Found checkbox element with role: \(role ?? "nil")")
    }
    if isTextArea {
      debugLog("Found text area element with role: \(role ?? "nil")")
    }
    if isPopUpButton {
      debugLog("Found pop-up button element with role: \(role ?? "nil")")
    }
    if isMenuItem {
      debugLog("Found menu item element with role: \(role ?? "nil")")
    }
    if isClickableGroup {
      debugLog("Found clickable group element with role: \(role ?? "nil")")
    }

    // Only process clickable elements
    guard
      isActionable || isLink || isButton || isRadioButton || isTab || isTextField || isCheckBox
        || isTextArea
        || isPopUpButton || isMenuItem || isClickableGroup
    else {
      // Skip non-clickable elements but traverse their children
      processChildren(
        of: element,
        allScreenBounds: allScreenBounds,
        windowFrame: windowFrame,
        roleStats: &roleStats,
        elementCount: &elementCount,
        clickableElements: &clickableElements,
        depth: depth
      )
      return
    }

    // Validate we have position and size
    guard let position = attributes.position,
      let size = attributes.size,
      isValidElementSize(size)
    else {
      let positionStr = attributes.position.map { "\($0)" } ?? "nil"
      let sizeStr = attributes.size.map { "\($0)" } ?? "nil"
      let elementType: String
      if isTab {
        elementType = "Tab"
      } else if isButton {
        elementType = "Button"
      } else if isTextField {
        elementType = "TextField"
      } else if isCheckBox {
        elementType = "CheckBox"
      } else if isTextArea {
        elementType = "TextArea"
      } else if isPopUpButton {
        elementType = "PopUpButton"
      } else if isMenuItem {
        elementType = "MenuItem"
      } else if isClickableGroup {
        elementType = "Group"
      } else if isLink {
        elementType = "Link"
      } else {
        elementType = "RadioButton"
      }
      debugLog(
        "\(elementType) filtered out - missing position/size or invalid size. position: \(positionStr), size: \(sizeStr)"
      )
      processChildren(
        of: element,
        allScreenBounds: allScreenBounds,
        windowFrame: windowFrame,
        roleStats: &roleStats,
        elementCount: &elementCount,
        clickableElements: &clickableElements,
        depth: depth
      )
      return
    }

    // Filter out window control buttons (close, minimize, full screen)
    // But always include tab buttons
    if isButton && !isTab && isWindowControlButton(element: element) {
      debugLog("Filtering out window control button")
      // Don't process children of window control buttons
      return
    }

    let frame = CGRect(x: position.x, y: position.y, width: size.width, height: size.height)
    let defaultTitle: String
    if isLink {
      defaultTitle = "Link"
    } else if isTab {
      defaultTitle = "Tab"
    } else if isTextField {
      defaultTitle = "TextField"
    } else if isCheckBox {
      defaultTitle = "CheckBox"
    } else if isTextArea {
      defaultTitle = "TextArea"
    } else if isPopUpButton {
      defaultTitle = "PopUpButton"
    } else if isMenuItem {
      defaultTitle = "MenuItem"
    } else if isClickableGroup {
      defaultTitle = "Button"
    } else if isRadioButton {
      defaultTitle = "RadioButton"
    } else if isActionable {
      defaultTitle = "Actionable"
    } else {
      defaultTitle = "Button"
    }

    // For clickable groups (toolbar buttons), prefer AXHelp attribute which often contains descriptive text
    var displayTitle: String?
    if isClickableGroup {
      var help: AnyObject?
      if AXUIElementCopyAttributeValue(element, kAXHelpAttribute as CFString, &help) == .success,
        let helpText = help as? String, !helpText.isEmpty
      {
        displayTitle = helpText
      }
    }

    // Fall back to title or description if not set
    let resolvedTitle =
      displayTitle ?? attributes.title ?? getElementDescription(element) ?? defaultTitle
    let trimmedTitle = resolvedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let finalTitle = trimmedTitle.isEmpty ? defaultTitle : trimmedTitle

    // Debug logging for buttons, tabs, text fields, checkboxes, text areas, pop-up buttons, menu items, and clickable groups
    if isButton || isTab || isTextField || isCheckBox || isTextArea || isPopUpButton || isMenuItem
      || isClickableGroup
    {
      let elementType: String
      if isTab {
        elementType = "tab"
      } else if isTextField {
        elementType = "text field"
      } else if isCheckBox {
        elementType = "checkbox"
      } else if isTextArea {
        elementType = "text area"
      } else if isPopUpButton {
        elementType = "pop-up button"
      } else if isMenuItem {
        elementType = "menu item"
      } else if isClickableGroup {
        elementType = "toolbar button"
      } else {
        elementType = "button"
      }
      debugLog(
        "Processing \(elementType) '\(finalTitle)' at frame: \(frame), enabled: \(attributes.enabled ?? true)"
      )
      if let scrollArea = currentScrollArea {
        debugLog("Current scroll area: \(scrollArea)")
      }
    }

    // Apply visibility filters using context state
    if isElementVisible(
      frame: frame,
      screenBounds: allScreenBounds,
      windowFrame: windowFrame,
      title: finalTitle)
    {

      if isButton || isTab || isTextField || isCheckBox || isTextArea || isPopUpButton || isMenuItem
        || isClickableGroup
      {
        let elementType: String
        if isTab {
          elementType = "tab"
        } else if isTextField {
          elementType = "text field"
        } else if isCheckBox {
          elementType = "checkbox"
        } else if isTextArea {
          elementType = "text area"
        } else if isPopUpButton {
          elementType = "pop-up button"
        } else if isMenuItem {
          elementType = "menu item"
        } else if isClickableGroup {
          elementType = "toolbar button"
        } else {
          elementType = "button"
        }
        debugLog("Adding \(elementType) '\(finalTitle)' to clickable elements")
      }

      let clickable = ClickableElement(
        axElement: element,
        frame: frame,
        title: finalTitle,
        role: role ?? "Unknown",
        isEnabled: attributes.enabled ?? true,
        actions: getElementActions(element: element)
      )
      clickableElements.append(clickable)
    } else if isButton || isTab || isTextField || isCheckBox || isTextArea || isPopUpButton
      || isMenuItem || isClickableGroup
    {
      let elementType: String
      if isTab {
        elementType = "Tab"
      } else if isTextField {
        elementType = "TextField"
      } else if isCheckBox {
        elementType = "CheckBox"
      } else if isTextArea {
        elementType = "TextArea"
      } else if isPopUpButton {
        elementType = "PopUpButton"
      } else if isMenuItem {
        elementType = "MenuItem"
      } else if isClickableGroup {
        elementType = "ToolbarButton"
      } else {
        elementType = "Button"
      }
      debugLog("\(elementType) '\(finalTitle)' filtered out by visibility check")
    }

    // Recursively process all children
    processChildren(
      of: element,
      allScreenBounds: allScreenBounds,
      windowFrame: windowFrame,
      roleStats: &roleStats,
      elementCount: &elementCount,
      clickableElements: &clickableElements,
      depth: depth
    )
  }

  // MARK: - Helper Methods

  /// Checks if an element is a tab button (should be included in clickable elements)
  private func isTabButton(element: AXUIElement) -> Bool {
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

  /// Gets all available actions for an element
  private func getElementActions(element: AXUIElement) -> [String] {
    var actionNames: CFArray?
    let result = AXUIElementCopyActionNames(element, &actionNames)

    guard result == .success, let actions = actionNames as? [String] else {
      return []
    }

    return actions
  }

  /// Checks if an element has a specific action (or one of the default actions)
  private func hasAction(element: AXUIElement, _ action: String = kAXPressAction as String) -> Bool {
    let actions = getElementActions(element: element)
    
    // If checking for press action, also accept open action as alternative
    if action == kAXPressAction as String {
      return actions.contains(kAXPressAction as String) || actions.contains("AXOpen")
    }
    
    return actions.contains(action)
  }

  /// Checks if an element is a window control button (close, minimize, full screen)
  /// These buttons should be excluded from clickable element selection
  private func isWindowControlButton(element: AXUIElement) -> Bool {
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
  struct BatchAttributes {
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
  private func getBatchAttributes(element: AXUIElement) -> BatchAttributes {
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

  /// Checks if element size is valid (positive width and height)
  private func isValidElementSize(_ size: CGSize) -> Bool {
    return size.width > 0 && size.height > 0
  }

  /// Gets display title for an element, with fallback to "Link" if none found
  private func getDisplayTitle(for element: AXUIElement) -> String {
    let title =
      element.get(Ax.titleAttr)
      ?? getElementDescription(element)
      ?? ""
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedTitle.isEmpty ? "Link" : trimmedTitle
  }

  /// Checks if element is visible based on context state
  ///
  /// Uses context tracking to filter elements:
  /// 1. Screen bounds check (multi-monitor aware)
  /// 2. Scroll container visibility (50% threshold)
  /// 3. Chrome area exclusion (via currentIsInChrome flag)
  ///
  /// - Parameters:
  ///   - frame: Element's frame in screen coordinates
  ///   - screenBounds: Array of all screen bounds
  ///   - windowFrame: Window frame in screen coordinates
  ///   - title: Element title (for debug logging)
  /// - Returns: true if element should be displayed
  private func isElementVisible(
    frame: CGRect,
    screenBounds: [CGRect],
    windowFrame: CGRect?,
    title: String
  ) -> Bool {
    // First check: Is element on screen (for elements with screen coordinates)
    let isOnScreen = screenBounds.contains { $0.intersects(frame) }

    // Second check: For elements in scroll containers, require 50% visibility
    if let scrollArea = currentScrollArea {
      let intersection = scrollArea.intersection(frame)

      // Calculate visible percentage
      let elementArea = frame.width * frame.height
      guard elementArea > 0 else {
        debugLog("Filtering out '\(title)' - zero area element")
        return false
      }

      let visibleArea = intersection.width * intersection.height
      let visibilityPercentage = visibleArea / elementArea

      let isVisible = visibilityPercentage >= 0.5

      if isVisible {
        debugLog(
          "Including '\(title)' - element at \(frame) is \(Int(visibilityPercentage * 100))% visible in scroll area \(scrollArea)"
        )
      } else {
        debugLog(
          "Filtering out '\(title)' - element at \(frame) is only \(Int(visibilityPercentage * 100))% visible (< 50%) in scroll area \(scrollArea)"
        )
      }

      return isVisible
    }

    // No scroll container - use screen bounds check
    if isOnScreen {
      debugLog("Including '\(title)' - element at \(frame) is on screen")
      return true
    }

    debugLog("Filtering out '\(title)' - off screen at \(frame)")
    return false
  }

  /// Processes all children of an element recursively
  private func processChildren(
    of element: AXUIElement,
    allScreenBounds: [CGRect],
    windowFrame: CGRect?,
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
      traverseElement(
        child,
        allScreenBounds: allScreenBounds,
        windowFrame: windowFrame,
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
  private func getElementDescription(_ element: AXUIElement) -> String? {
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

  // MARK: - Static Methods

  /// Collects all visible clickable elements from the frontmost application window
  static func collectClickableElements() -> [ClickableElement] {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
      debugLog("No frontmost app")
      return []
    }

    let axApp = AXUIElementCreateApplication(frontmostApp.processIdentifier)

    // Enhanced UI mode may help expose more web content in some browsers
    axApp.set(Ax.enhancedUserInterfaceAttr, true)

    guard let focusedWindow = axApp.get(Ax.focusedWindowAttr) else {
      debugLog("No focused window")
      return []
    }

    // Create interface instance and collect elements
    let interface = AXInterface(root: focusedWindow)
    return interface.collectClickableElements()
  }

  /// Performs a click action on the given element
  static func clickElement(_ element: ClickableElement) -> Bool {
    // Try actions in priority order: press first, then open
    let actionsToTry: [String] = [kAXPressAction as String, "AXOpen"]
    
    for action in actionsToTry {
      // Only try actions that the element supports
      guard element.actions.contains(action) else { continue }
      
      let result = AXUIElementPerformAction(element.axElement, action as CFString)
      
      if result == .success {
        print("Successfully clicked: \(element.title) using action: \(action)")
        return true
      } else {
        debugLog("Failed to click element: \(element.title) with action: \(action), error: \(result.rawValue)")
      }
    }
    
    print("Failed to click element: \(element.title) - no supported actions succeeded")
    return false
  }
}
