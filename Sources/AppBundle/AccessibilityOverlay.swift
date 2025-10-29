import SwiftUI
import Cocoa

// MARK: - Models

/// Represents a clickable UI element found via accessibility API
struct ClickableElement: Identifiable {
  let id = UUID()
  let axElement: AXUIElement
  let frame: CGRect
  let title: String
  let role: String
  let isEnabled: Bool
}

// MARK: - Main Overlay Controller

/// Manages the accessibility overlay that highlights clickable elements
/// Activated via RCMD+O keyboard shortcut
class AccessibilityOverlay: NSObject {
  static let shared = AccessibilityOverlay()
  
  private var window: NSWindow?
  private var clickableElements: [ClickableElement] = []
  
  private override init() {
    super.init()
  }
  
  // MARK: - Public Interface
  
  func show() {
    guard window == nil else {
      window?.orderFrontRegardless()
      return
    }
    
    // Show loading indicator immediately for better UX
    showLoadingOverlay()
    
    // Collect clickable elements in background to avoid blocking UI
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }
      
      self.collectClickableElements()
      
      // Update UI on main thread
      DispatchQueue.main.async {
        self.updateOverlayWithElements()
      }
    }
  }
  
  func hide() {
    window?.orderOut(nil)
    window = nil
    clickableElements = []
  }
  
  func isVisible() -> Bool {
    return window != nil
  }
  
  // MARK: - Window Management
  
  private func showLoadingOverlay() {
    // Get the screen containing the mouse cursor
    let mouseLocation = NSEvent.mouseLocation
    let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
    
    guard let screen = targetScreen else {
      print("DEBUG: No screen found")
      return
    }
    
    let screenFrame = screen.frame
    print("DEBUG: Creating overlay on screen: \(screenFrame), mouse at: \(mouseLocation)")
    
    let contentView = LoadingOverlayView(onDismiss: { [weak self] in
      self?.hide()
    })
    let hostingView = NSHostingView(rootView: contentView)
    
    // Create window with a simple rect, then move it to the correct screen
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    
    window.contentView = hostingView
    window.backgroundColor = .clear
    window.isOpaque = false
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.ignoresMouseEvents = false
    
    // Now set the frame to cover the entire screen
    window.setFrame(screenFrame, display: false)
    window.orderFrontRegardless()
    
    self.window = window
    
    print("DEBUG: Window positioned: \(window.frame), screen: \(window.screen?.frame ?? .zero)")
  }
  

  private func updateOverlayWithElements() {
    guard let window = self.window, let screen = window.screen else {
      print("DEBUG: No window or screen available")
      return
    }
    
    let screenFrame = screen.frame
    print("DEBUG: Overlay on screen: \(screenFrame), found \(clickableElements.count) elements")
    
    // Debug: print first few element positions
    for (index, element) in clickableElements.prefix(3).enumerated() {
      print("DEBUG: Element \(index + 1) '\(element.title)' at \(element.frame)")
    }
    
    let contentView = AccessibilityOverlayView(
      elements: clickableElements,
      screenFrame: screenFrame,
      onElementClick: { [weak self] element in
        self?.clickElement(element)
      },
      onDismiss: { [weak self] in
        self?.hide()
      }
    )
    let hostingView = NSHostingView(rootView: contentView)
    
    window.contentView = hostingView
    
    print("DEBUG: Overlay view updated with \(clickableElements.count) elements")
  }
  
  // MARK: - Element Collection
  
  /// Collects all visible clickable elements from the frontmost application window
  private func collectClickableElements() {
    clickableElements = []
    
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
      print("DEBUG: No frontmost app")
      return
    }
    
    let axApp = AXUIElementCreateApplication(frontmostApp.processIdentifier)
    
    // Enhanced UI mode may help expose more web content in some browsers
    axApp.set(Ax.enhancedUserInterfaceAttr, true)
    
    guard let focusedWindow = axApp.get(Ax.focusedWindowAttr) else {
      return
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
      depth: 0
    )
    
    print("DEBUG: Collected \(clickableElements.count) elements")
  }
  
  /// Recursively traverses the accessibility tree to find clickable elements
  ///
  /// This function implements several important filtering rules:
  /// 1. Only processes elements within recursion depth limit
  /// 2. Tracks scroll containers (AXScrollArea, AXWebArea) to determine visibility
  /// 3. Filters out elements that are off-screen (multi-monitor aware)
  /// 4. Filters out elements scrolled outside their container's visible bounds
  ///
  /// - Parameters:
  ///   - element: Current AXUIElement being examined
  ///   - allScreenBounds: Bounds of all connected screens
  ///   - containerFrame: Visible bounds of nearest scroll container ancestor (nil if none)
  ///   - roleStats: Statistics tracking element roles encountered (for debugging)
  ///   - elementCount: Total elements processed (for debugging)
  ///   - depth: Current recursion depth (prevents infinite loops)
  private func collectElementsRecursively(
    from element: AXUIElement,
    allScreenBounds: [CGRect],
    containerFrame: CGRect?,
    roleStats: inout [String: Int],
    elementCount: inout Int,
    depth: Int
  ) {
    // Prevent infinite recursion in malformed accessibility trees
    guard depth < 50 else { return }
    
    elementCount += 1
    
    let role = element.get(Ax.roleAttr)
    if let role = role {
      roleStats[role, default: 0] += 1
    }
    
    let position = element.get(Ax.topLeftCornerAttr)
    let size = element.get(Ax.sizeAttr)
    
    // Update container bounds when we encounter scroll areas
    // Nested containers are intersected to get the most restrictive visible bounds
    let currentContainerFrame = updateContainerFrame(
      existingContainer: containerFrame,
      element: element,
      role: role,
      position: position,
      size: size
    )
    
    // Check if this is a clickable link that should be displayed
    if let position = position, 
       let size = size, 
       let role = role, 
       role == "AXLink",
       isValidElementSize(size) {
      
      let frame = CGRect(x: position.x, y: position.y, width: size.width, height: size.height)
      let displayTitle = getDisplayTitle(for: element)
      
      // Apply visibility filters
      if isElementVisible(frame: frame, 
                         screenBounds: allScreenBounds, 
                         containerFrame: currentContainerFrame,
                         title: displayTitle) {
        
        let isEnabled = element.get(Ax.enabledAttr) ?? true
        
        let clickable = ClickableElement(
          axElement: element,
          frame: frame,
          title: displayTitle,
          role: role,
          isEnabled: isEnabled
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
      depth: depth
    )
  }
  
  // MARK: - Helper Methods
  
  /// Updates the container frame when encountering scroll areas
  /// Nested containers are intersected to get the most restrictive visible area
  private func updateContainerFrame(
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
  private func isValidElementSize(_ size: CGSize) -> Bool {
    return size.width > 0 && size.height > 0
  }
  
  /// Gets display title for an element, with fallback to "Link" if none found
  private func getDisplayTitle(for element: AXUIElement) -> String {
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
  private func isElementVisible(
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
  private func processChildren(
    of element: AXUIElement,
    allScreenBounds: [CGRect],
    containerFrame: CGRect?,
    roleStats: inout [String: Int],
    elementCount: inout Int,
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
        depth: depth + 1
      )
    }
  }
  
  /// Attempts to get a description for an element by checking various attributes
  /// Tries in order: description, value, role description, URL
  private func getElementDescription(_ element: AXUIElement) -> String? {
    // Try description attribute
    var description: AnyObject?
    if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &description) == .success,
       let desc = description as? String, !desc.isEmpty {
      return desc
    }
    
    // Try value (especially useful for text fields)
    var value: AnyObject?
    if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success {
      if let val = value as? String, !val.isEmpty {
        return String(val.prefix(50)) // Limit length for display
      }
    }
    
    // Try role description
    var roleDescription: AnyObject?
    if AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &roleDescription) == .success,
       let roleDesc = roleDescription as? String, !roleDesc.isEmpty {
      return roleDesc
    }
    
    // Try URL for links
    var url: AnyObject?
    if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &url) == .success,
       let urlValue = url as? URL {
      return urlValue.absoluteString
    }
    
    return nil
  }
  
  // MARK: - Element Interaction
  
  /// Performs a click action on the given element
  private func clickElement(_ element: ClickableElement) {
    let result = AXUIElementPerformAction(element.axElement, kAXPressAction as CFString)
    
    if result == .success {
      print("Successfully clicked: \(element.title)")
      // Hide overlay after successful click with brief delay for visual feedback
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.hide()
      }
    } else {
      print("Failed to click element: \(element.title), error: \(result.rawValue)")
    }
  }
}

// MARK: - SwiftUI Views

/// Loading indicator shown while scanning for elements
struct LoadingOverlayView: View {
  let onDismiss: () -> Void
  
  var body: some View {
    ZStack {
      // Dismissable background
      Color.black.opacity(0.3)
        .onTapGesture {
          onDismiss()
        }
      
      // Loading indicator
      VStack(spacing: 12) {
        ProgressView()
          .scaleEffect(1.5)
          .progressViewStyle(CircularProgressViewStyle(tint: .white))
        
        Text("Scanning for links...")
          .font(.system(size: 16, weight: .medium))
          .foregroundColor(.white)
      }
      .padding(24)
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(Color.black.opacity(0.8))
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Main overlay view displaying clickable elements with numbered hints
struct AccessibilityOverlayView: View {
  let elements: [ClickableElement]
  let screenFrame: CGRect
  let onElementClick: (ClickableElement) -> Void
  let onDismiss: () -> Void
  
  @State private var hoveredIndex: Int?
  
  var body: some View {
    GeometryReader { geometry in
      ZStack {
        // Semi-transparent background that can be clicked to dismiss
        Color.black.opacity(0.3)
          .frame(width: geometry.size.width, height: geometry.size.height)
          .contentShape(Rectangle())
          .onTapGesture {
            print("DEBUG: Background tapped")
            onDismiss()
          }
        
        // Numbered hint badges for each element
        ForEach(Array(elements.enumerated()), id: \.element.id) { index, element in
          elementHint(for: element, index: index + 1, geometrySize: geometry.size)
        }
        
        // Tooltips layer (rendered on top of hints)
        ForEach(Array(elements.enumerated()), id: \.element.id) { index, element in
          if hoveredIndex == index + 1 {
            elementTooltip(for: element, geometrySize: geometry.size)
          }
        }
        
        // Instructions banner
        instructionsBanner
      }
    }
    .edgesIgnoringSafeArea(.all)
  }
  
  // MARK: - View Components
  
  /// Creates a numbered square hint badge at the top-left of an element
  private func elementHint(for element: ClickableElement, index: Int, geometrySize: CGSize) -> some View {
    let hintSize: CGFloat = 28
    let isHovered = hoveredIndex == index
    
    // Coordinate conversion:
    // Accessibility API gives us: Y=0 at BOTTOM-left of primary display (screen coordinates)
    // SwiftUI view: Y=0 at TOP-left of our window
    // Our window: positioned at screenFrame
    
    // Step 1: X is straightforward - just subtract screen origin
    let viewX = element.frame.minX - screenFrame.minX
    
    // Step 2: Y needs flipping
    // Element is at screen Y (measured from bottom)
    // We want view Y (measured from top of our window)
    // screenFrame.maxY is the top of the screen in screen coordinates
    // element.frame.minY is the bottom of the element in screen coordinates
    let viewY = screenFrame.maxY - element.frame.minY - element.frame.height
    
    // Only print first 3 hints to reduce console spam
    if index <= 3 {
      print("DEBUG: Hint \(index) '\(element.title)' - elem(\(element.frame.minX), \(element.frame.minY)), screen(\(screenFrame)), view(\(viewX), \(viewY))")
    }
    
    return ZStack {
      // Square background
      RoundedRectangle(cornerRadius: 4)
        .fill(isHovered ? Color.blue : Color.green)
      
      // Index number
      Text("\(index)")
        .font(.system(size: 13, weight: .bold))
        .foregroundColor(.white)
    }
    .frame(width: hintSize, height: hintSize)
    .position(x: viewX + hintSize/2, y: viewY + hintSize/2)
    .opacity(element.isEnabled ? 1.0 : 0.5)
    .contentShape(Rectangle())
    .onHover { isHovered in
      hoveredIndex = isHovered ? index : nil
    }
    .onTapGesture {
      print("DEBUG: Tapped hint \(index) for '\(element.title)'")
      onElementClick(element)
    }
  }
  
  /// Creates a tooltip showing element title and role when hovering over hint
  private func elementTooltip(for element: ClickableElement, geometrySize: CGSize) -> some View {
    // Convert screen coordinates to view coordinates (same as hint)
    let viewX = element.frame.minX - screenFrame.minX + 32  // Offset to the right
    let viewY = screenFrame.maxY - element.frame.minY - element.frame.height
    
    return VStack(alignment: .leading, spacing: 4) {
      Text(element.title)
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.white)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
      
      Text(roleDisplayName(element.role))
        .font(.system(size: 9))
        .foregroundColor(.white.opacity(0.8))
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(maxWidth: 250, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(Color.black.opacity(0.95))
        .shadow(color: .black.opacity(0.5), radius: 6, x: 2, y: 2)
    )
    .position(x: viewX, y: viewY)
    .allowsHitTesting(false)  // Don't intercept clicks
  }
  
  /// Instructions banner at the top of the overlay
  private var instructionsBanner: some View {
    VStack {
      HStack {
        Spacer()
        Text("Click numbered hint to open link • Hover to see link title • Press ESC or click background to dismiss")
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(.white)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 8)
              .fill(Color.black.opacity(0.8))
          )
          .padding()
        Spacer()
      }
      Spacer()
    }
  }
  
  // MARK: - Helpers
  
  /// Converts accessibility role names to human-readable display names
  private func roleDisplayName(_ role: String) -> String {
    let mapping: [String: String] = [
      kAXButtonRole: "Button",
      kAXCheckBoxRole: "Checkbox",
      kAXRadioButtonRole: "Radio",
      kAXPopUpButtonRole: "Popup",
      kAXMenuButtonRole: "Menu",
      "AXLink": "Link",
      "AXTab": "Tab",
      kAXStaticTextRole: "Text",
      kAXTextFieldRole: "Text Field",
      kAXTextAreaRole: "Text Area",
      kAXComboBoxRole: "Combo Box",
      kAXSliderRole: "Slider",
      kAXIncrementorRole: "Stepper",
      kAXDisclosureTriangleRole: "Disclosure",
    ]
    return mapping[role] ?? role.replacingOccurrences(of: "AX", with: "")
  }
}
