import Cocoa
import ApplicationServices

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
    
    // Support multiple monitors by checking all screen bounds
    let allScreenBounds = NSScreen.screens.map { $0.frame }
    
    var roleStats: [String: Int] = [:]
    var elementCount = 0
    
    // Recursively traverse accessibility tree starting from focused window
    collectElementsRecursively(
      from: focusedWindow,
      allScreenBounds: allScreenBounds,
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
        containerFrame: containerFrame,
        roleStats: &roleStats,
        elementCount: &elementCount,
        clickableElements: &clickableElements,
        depth: depth
      )
      return
    }
    
    roleStats[role, default: 0] += 1
    
    // Only fetch position/size if this is a link or scroll container
    let isLink = role == "AXLink"
    let isScrollContainer = role == "AXScrollArea" || role == "AXWebArea"
    
    guard isLink || isScrollContainer else {
      // Skip fetching attributes for non-link, non-container elements
      processChildren(
        of: element,
        allScreenBounds: allScreenBounds,
        containerFrame: containerFrame,
        roleStats: &roleStats,
        elementCount: &elementCount,
        clickableElements: &clickableElements,
        depth: depth
      )
      return
    }
    
    // OPTIMIZATION: Batch fetch common attributes for links and scroll containers
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
    
    // Check if this is a clickable link that should be displayed
    if isLink,
       let position = attributes.position, 
       let size = attributes.size, 
       isValidElementSize(size) {
      
      let frame = CGRect(x: position.x, y: position.y, width: size.width, height: size.height)
      let displayTitle = attributes.title ?? getElementDescription(element) ?? "Link"
      let trimmedTitle = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      let finalTitle = trimmedTitle.isEmpty ? "Link" : trimmedTitle
      
      // Apply visibility filters
      if isElementVisible(frame: frame, 
                         screenBounds: allScreenBounds, 
                         containerFrame: currentContainerFrame,
                         title: finalTitle) {
        
        let clickable = ClickableElement(
          axElement: element,
          frame: frame,
          title: finalTitle,
          role: role,
          isEnabled: attributes.enabled ?? true
        )
        clickableElements.append(clickable)
      }
    }
    
    // Recursively process all children
    processChildren(
      of: element,
      allScreenBounds: allScreenBounds,
      containerFrame: currentContainerFrame,
      roleStats: &roleStats,
      elementCount: &elementCount,
      clickableElements: &clickableElements,
      depth: depth
    )
  }
  
  // MARK: - Helper Methods
  
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
      kAXTitleAttribute as CFString
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
          values.count == attributes.count else {
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
       CFGetTypeID(values[0]) == AXValueGetTypeID() {
      let axValue = values[0] as! AXValue
      var pos = CGPoint.zero
      if AXValueGetValue(axValue, .cgPoint, &pos) {
        position = pos
      }
    }
    
    // Size (index 1) - stored as AXValue (CGSize)
    var size: CGSize? = nil
    if values.count > 1,
       CFGetTypeID(values[1]) == AXValueGetTypeID() {
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
  /// Nested containers are intersected to get the most restrictive visible area
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
          (role == "AXScrollArea" || role == "AXWebArea") else {
      return existingContainer
    }
    
    let frame = CGRect(x: position.x, y: position.y, width: size.width, height: size.height)
    print("DEBUG: Found \(role) container at \(frame)")
    
    // If we already have a parent container, intersect to get visible area
    // This handles nested scroll areas correctly
    if let existingContainer = existingContainer {
      let intersection = existingContainer.intersection(frame)
      print("DEBUG: Intersected with existing container: \(intersection)")
      return intersection
    }
    
    return frame
  }
  
  /// Checks if element size is valid (positive width and height)
  private static func isValidElementSize(_ size: CGSize) -> Bool {
    return size.width > 0 && size.height > 0
  }
  
  /// Gets display title for an element, with fallback to "Link" if none found
  private static func getDisplayTitle(for element: AXUIElement) -> String {
    let title = element.get(Ax.titleAttr) 
      ?? getElementDescription(element)
      ?? ""
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedTitle.isEmpty ? "Link" : trimmedTitle
  }
  
  /// Checks if element is visible based on screen bounds and container clipping
  ///
  /// An element is visible if:
  /// 1. It intersects with at least one screen (multi-monitor support)
  /// 2. If inside a scroll container, it must intersect with that container's visible bounds
  ///
  /// - Parameters:
  ///   - frame: Element's frame in screen coordinates
  ///   - screenBounds: Array of all screen bounds
  ///   - containerFrame: Optional container bounds (nil if not in a scroll area)
  ///   - title: Element title (for debug logging)
  /// - Returns: true if element should be displayed
  private static func isElementVisible(
    frame: CGRect,
    screenBounds: [CGRect],
    containerFrame: CGRect?,
    title: String
  ) -> Bool {
    // Filter 1: Must be on at least one screen
    let isOnScreen = screenBounds.contains { $0.intersects(frame) }
    
    guard isOnScreen else {
      print("DEBUG: Filtering out '\(title)' - off screen at \(frame)")
      return false
    }
    
    // Filter 2: Must be within scroll container's visible bounds (if any)
    if let container = containerFrame {
      let intersects = container.intersects(frame)
      if !intersects {
        print("DEBUG: Filtering out '\(title)' - element at \(frame) outside container \(container)")
      } else {
        print("DEBUG: Including '\(title)' - element at \(frame) inside container \(container)")
      }
      return intersects
    }
    
    // No container restrictions, element is visible
    print("DEBUG: No container for element at \(frame), including by default")
    return true
  }
  
  /// Processes all children of an element recursively
  private static func processChildren(
    of element: AXUIElement,
    allScreenBounds: [CGRect],
    containerFrame: CGRect?,
    roleStats: inout [String: Int],
    elementCount: inout Int,
    clickableElements: inout [ClickableElement],
    depth: Int
  ) {
    var children: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
          let childElements = children as? [AXUIElement] else {
      return
    }
    
    for child in childElements {
      collectElementsRecursively(
        from: child,
        allScreenBounds: allScreenBounds,
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
      kAXURLAttribute as CFString
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
          let values = valuesArray as? [AnyObject] else {
      return nil
    }
    
    // Process attributes in priority order (values correspond to attributes by index)
    // Handle missing attributes gracefully - they may be NSNull or missing from array
    // 1. Try description attribute
    if values.count > 0,
       let desc = values[0] as? String, !desc.isEmpty {
      return desc
    }
    
    // 2. Try value (especially useful for text fields)
    if values.count > 1,
       let val = values[1] as? String, !val.isEmpty {
      return String(val.prefix(50)) // Limit length for display
    }
    
    // 3. Try role description
    if values.count > 2,
       let roleDesc = values[2] as? String, !roleDesc.isEmpty {
      return roleDesc
    }
    
    // 4. Try URL for links
    if values.count > 3,
       let urlValue = values[3] as? URL {
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

