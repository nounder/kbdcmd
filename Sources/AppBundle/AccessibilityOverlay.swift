import SwiftUI
import Cocoa
import ObjectiveC

// MARK: - Keyboard Input Coordinator

/// ObservableObject that handles keyboard input for the overlay
class KeyboardInputCoordinator: ObservableObject {
  let elements: [ClickableElement]
  let onElementClick: (ClickableElement) -> Void
  let onDismiss: () -> Void
  
  @Published var typedPrefix: String = ""
  
  init(elements: [ClickableElement], onElementClick: @escaping (ClickableElement) -> Void, onDismiss: @escaping () -> Void) {
    self.elements = elements
    self.onElementClick = onElementClick
    self.onDismiss = onDismiss
  }
  
  /// Handles keyboard events for typing index numbers
  func handleKeyEvent(_ event: NSEvent) -> Bool {
    // ESC key dismisses overlay
    if event.keyCode == 53 {  // ESC key
      typedPrefix = ""
      onDismiss()
      return true
    }
    
    // Backspace/Delete clears prefix
    if event.keyCode == 51 || event.keyCode == 117 {  // Backspace or Delete
      if !typedPrefix.isEmpty {
        typedPrefix = String(typedPrefix.dropLast())
      }
      return true
    }
    
    // Check if it's a digit (0-9)
    if let characters = event.characters, let firstChar = characters.first,
       firstChar.isNumber {
      let newPrefix = typedPrefix + String(firstChar)
      
      // Check if any element matches this prefix
      let hasMatch = elements.enumerated().contains { index, _ in
        String(index + 1).hasPrefix(newPrefix)
      }
      
      if hasMatch {
        typedPrefix = newPrefix
        
        // Check if exactly one match after updating prefix
        let matchingElements = getMatchingElements(for: typedPrefix)
        
        // Auto-click if exactly one match
        if matchingElements.count == 1, let match = matchingElements.first {
          // Use a small delay to allow visual feedback
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.onElementClick(match.element)
          }
        }
        
        return true
      }
    }
    
    return false
  }
  
  func getMatchingElements(for prefix: String) -> [(index: Int, element: ClickableElement)] {
    guard !prefix.isEmpty else {
      return elements.enumerated().map { (index: $0.offset + 1, element: $0.element) }
    }
    
    return elements.enumerated()
      .filter { String($0.offset + 1).hasPrefix(prefix) }
      .map { (index: $0.offset + 1, element: $0.element) }
  }
}

// MARK: - Custom Window for Keyboard Input

/// Custom NSWindow that captures keyboard events for the overlay
class AccessibilityOverlayWindow: NSWindow {
  var onKeyDown: ((NSEvent) -> Bool)?  // Returns true if event was handled
  
  override func keyDown(with event: NSEvent) {
    if let onKeyDown = onKeyDown, onKeyDown(event) {
      return  // Event was handled
    }
    super.keyDown(with: event)
  }
  
  override var acceptsFirstResponder: Bool {
    return true
  }
}

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
  private var keyboardCoordinator: KeyboardInputCoordinator?
  
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
    keyboardCoordinator = nil
  }
  
  func isVisible() -> Bool {
    return window != nil
  }
  
  /// Handles keyboard events from CGEvent tap (called from KeyListener)
  func handleKeyboardEvent(keyCode: Int64, characters: String?) -> Bool {
    guard let coordinator = keyboardCoordinator else { return false }
    
    // Create a synthetic NSEvent for the coordinator
    // We need to convert CGEvent keyCode to NSEvent
    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: NSEvent.mouseLocation,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window?.windowNumber ?? 0,
      context: nil,
      characters: characters ?? "",
      charactersIgnoringModifiers: characters ?? "",
      isARepeat: false,
      keyCode: UInt16(keyCode)
    )
    
    guard let event = event else { return false }
    
    return coordinator.handleKeyEvent(event)
  }
  
  // MARK: - Window Management
  
  private func showLoadingOverlay() {
    // Get mouse location to find which screen to show overlay on
    let mouseLocation = NSEvent.mouseLocation  
    let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
    
    guard let screen = targetScreen else {
      print("DEBUG: No screen found")
      return
    }
    
    print("DEBUG: Creating overlay on screen: \(screen.frame), mouse at: \(mouseLocation)")
    
    let contentView = LoadingOverlayView(onDismiss: { [weak self] in
      self?.hide()
    })
    let hostingView = NSHostingView(rootView: contentView)
    
    // Create a borderless window covering the target screen
    let window = AccessibilityOverlayWindow(
      contentRect: screen.frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    
    window.contentView = hostingView
    window.backgroundColor = .clear
    window.isOpaque = false  
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.ignoresMouseEvents = false  // Allow mouse events to pass through to SwiftUI
    window.orderFrontRegardless()
    
    self.window = window
    
    print("DEBUG: Window created at: \(window.frame)")
  }
  

  private func updateOverlayWithElements() {
    guard let window = self.window, let screen = window.screen else {
      print("DEBUG: No window or screen available")
      return
    }
    
    let screenFrame = screen.frame
    
    // The screen with the menu bar is always index 0 (the primary display)
    // This is the most reliable way to detect the primary screen
    let isPrimaryScreen = (screen == NSScreen.screens[0])
    
    print("DEBUG: Overlay on screen: \(screenFrame), found \(clickableElements.count) elements")
    
    // IMPORTANT: Coordinate system conversion issue
    // - NSWindow.frame uses bottom-left origin (AppKit/Cocoa convention)
    // - Accessibility API uses top-left origin (CGEvent convention)
    // - We need to convert: viewPos = elementGlobalPos - windowGlobalPos, with Y-axis flip
    let windowFrame = window.frame
    let contentViewBounds = window.contentView?.bounds ?? CGRect.zero
    
    print("DEBUG: Window frame: \(windowFrame), contentView bounds: \(contentViewBounds)")
    print("DEBUG: Screen frame: \(screenFrame), window screen: \(window.screen?.frame ?? .zero)")
    
    // Log element positions for debugging
    for (index, element) in clickableElements.enumerated() {
      print("DEBUG: Element \(index + 1) '\(element.title)' at global: \(element.frame)")
    }
    
    // Create keyboard event coordinator
    let keyboardCoordinator = KeyboardInputCoordinator(
      elements: clickableElements,
      onElementClick: { [weak self] element in
        self?.clickElement(element)
      },
      onDismiss: { [weak self] in
        self?.hide()
      }
    )
    self.keyboardCoordinator = keyboardCoordinator
    
    // Keyboard events are handled via CGEvent tap in KeyListener
    // when overlay is visible
    
    // Create the overlay view with keyboard input handling
    let overlayView = AccessibilityOverlayView(
      elements: clickableElements,
      windowFrame: windowFrame,
      windowHeight: windowFrame.height,
      isPrimaryScreen: isPrimaryScreen,
      keyboardCoordinator: keyboardCoordinator,
      onElementClick: { [weak self] element in
        self?.clickElement(element)
      },
      onDismiss: { [weak self] in
        self?.hide()
      }
    )
    let hostingView = NSHostingView(rootView: overlayView)
    
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
  let windowFrame: CGRect  // Window's frame in global screen coordinates
  let windowHeight: CGFloat  // Window height for coordinate conversion
  let isPrimaryScreen: Bool
  let keyboardCoordinator: KeyboardInputCoordinator
  let onElementClick: (ClickableElement) -> Void
  let onDismiss: () -> Void
  
  @ObservedObject private var keyboardInput: KeyboardInputCoordinator
  
  init(
    elements: [ClickableElement],
    windowFrame: CGRect,
    windowHeight: CGFloat,
    isPrimaryScreen: Bool,
    keyboardCoordinator: KeyboardInputCoordinator,
    onElementClick: @escaping (ClickableElement) -> Void,
    onDismiss: @escaping () -> Void
  ) {
    self.elements = elements
    self.windowFrame = windowFrame
    self.windowHeight = windowHeight
    self.isPrimaryScreen = isPrimaryScreen
    self.keyboardCoordinator = keyboardCoordinator
    self.onElementClick = onElementClick
    self.onDismiss = onDismiss
    self._keyboardInput = ObservedObject(wrappedValue: keyboardCoordinator)
  }
  
  // Computed properties for matching elements
  private var matchingElements: [(index: Int, element: ClickableElement)] {
    keyboardCoordinator.getMatchingElements(for: keyboardCoordinator.typedPrefix)
  }
  
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
          let elementIndex = index + 1
          let typedPrefix = keyboardCoordinator.typedPrefix
          let isMatching = matchingElements.contains { $0.index == elementIndex }
          let matchedPrefixLength = typedPrefix.isEmpty ? 0 : (String(elementIndex).hasPrefix(typedPrefix) ? typedPrefix.count : 0)
          
          elementHint(
            for: element,
            index: elementIndex,
            geometrySize: geometry.size,
            isMatching: isMatching,
            matchedPrefixLength: matchedPrefixLength
          )
        }
        
        // Show typed prefix indicator
        if !keyboardCoordinator.typedPrefix.isEmpty {
          typedPrefixIndicator
        }
        
        // Instructions banner
        instructionsBanner
      }
    }
    .edgesIgnoringSafeArea(.all)
  }
  
  // MARK: - View Components
  
  /// Creates a numbered square hint badge at the top-left of an element
  private func elementHint(
    for element: ClickableElement,
    index: Int,
    geometrySize: CGSize,
    isMatching: Bool,
    matchedPrefixLength: Int
  ) -> some View {
    let hintSize: CGFloat = 28
    let indexString = String(index)
    
    // COORDINATE SYSTEM CONVERSION:
    // Accessibility API (kAXPositionAttribute) uses TOP-LEFT origin
    // NSWindow.frame uses BOTTOM-LEFT origin  
    // SwiftUI uses TOP-LEFT origin
    //
    // Conversion steps:
    // 1. X: Direct conversion (same horizontal system)
    // 2. Y: Convert window frame from bottom-left to top-left, then calculate relative position
    let viewX = element.frame.minX - windowFrame.minX
    
    // Y conversion: Both Accessibility API and SwiftUI use top-left origin
    // NSWindow.frame uses bottom-left origin, so convert window top edge to top-left origin
    // For multi-monitor setups, we need the total screen height of all screens combined
    // or the height of the screen containing the window
    // Accessibility API coordinates are relative to the top-left of the primary screen
    // So we need to find what Y coordinate corresponds to the window's top in top-left origin
    let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? windowHeight
    
    // Convert window's top edge from bottom-left origin to top-left origin
    // windowFrame.maxY is the top edge in bottom-left origin
    // In top-left origin, this would be: screenHeight - windowFrame.maxY
    let windowTopYInTopLeft = primaryScreenHeight - windowFrame.maxY  // Window top in top-left origin
    let elementTopYInTopLeft = element.frame.minY  // Already in top-left origin
    let elementYRelativeToWindow = elementTopYInTopLeft - windowTopYInTopLeft
    
    // Debug logging for coordinate conversion (first element only to avoid spam)
    if index == 1 {
      print("DEBUG: Coordinate conversion for element \(index) '\(element.title)':")
      print("DEBUG:   Element frame (global, top-left origin): \(element.frame)")
      print("DEBUG:   Window frame (global, bottom-left origin): \(windowFrame)")
      print("DEBUG:   Primary screen height: \(primaryScreenHeight)")
      print("DEBUG:   Window top in top-left origin: \(windowTopYInTopLeft)")
      print("DEBUG:   Element top in top-left origin: \(elementTopYInTopLeft)")
      print("DEBUG:   Element Y relative to window top: \(elementYRelativeToWindow)")
      print("DEBUG:   Calculated viewX: \(viewX), viewY: \(elementYRelativeToWindow) (top-left origin)")
      print("DEBUG:   Geometry size: \(geometrySize)")
    }
    
    // Use .position() for absolute positioning within the geometry
    // .position() sets the CENTER of the view at the given coordinates
    let posX = viewX + hintSize / 2  // Adjust for center-based positioning
    let posY = elementYRelativeToWindow + hintSize / 2
    
    return ZStack {
      // Square background - highlight if matching typed prefix
      RoundedRectangle(cornerRadius: 4)
        .fill(isMatching ? Color.orange : Color.green)
        .overlay(
          RoundedRectangle(cornerRadius: 4)
            .stroke(isMatching ? Color.white : Color.clear, lineWidth: 2)
        )
      
      // Index number with highlighting for matched prefix
      if matchedPrefixLength > 0 && matchedPrefixLength < indexString.count {
        // Show matched prefix in different color
        HStack(spacing: 0) {
          Text(String(indexString.prefix(matchedPrefixLength)))
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.white)
          
          Text(String(indexString.dropFirst(matchedPrefixLength)))
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.yellow)
        }
      } else {
        Text(indexString)
          .font(.system(size: 13, weight: .bold))
          .foregroundColor(.white)
      }
    }
    .frame(width: hintSize, height: hintSize)
    .position(x: posX, y: posY)
    .opacity(element.isEnabled ? 1.0 : 0.5)
    .contentShape(Rectangle())
    .onTapGesture {
      print("DEBUG: Tapped hint \(index) for '\(element.title)'")
      onElementClick(element)
    }
  }
  
  /// Instructions banner at the top of the overlay
  private var instructionsBanner: some View {
    VStack {
      HStack {
        Spacer()
        VStack(spacing: 4) {
          Text("Type number to select • Click hint to open link • Press ESC to dismiss")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
          
          if !keyboardCoordinator.typedPrefix.isEmpty {
            Text("Typed: \(keyboardCoordinator.typedPrefix)")
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(.yellow)
          }
        }
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
  
  /// Typed prefix indicator showing what the user has typed so far
  private var typedPrefixIndicator: some View {
    VStack {
      Spacer()
      HStack {
        Spacer()
        Text("Typed: \(keyboardCoordinator.typedPrefix)")
          .font(.system(size: 24, weight: .bold))
          .foregroundColor(.yellow)
          .padding(.horizontal, 20)
          .padding(.vertical, 12)
          .background(
            RoundedRectangle(cornerRadius: 8)
              .fill(Color.black.opacity(0.9))
              .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
          )
          .padding(.bottom, 100)
        Spacer()
      }
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
