import Cocoa
import SwiftUI

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

// MARK: - Hint Overlay Manager

/// Manages the UI overlay window and views for displaying clickable element hints
/// Coordinates between AXHelpers, keyboard input, and UI display
class HintOverlay {
  static let shared = HintOverlay()

  private var window: NSWindow?
  private var keyboardCoordinator: KeyboardInputCoordinator?

  var isVisible: Bool {
    return window != nil
  }

  private init() {}

  // MARK: - Public Interface

  /// Shows the accessibility overlay with clickable elements
  func show() {
    // If already visible, bring to front
    guard !isVisible else {
      bringToFront()
      return
    }

    // Show loading indicator immediately for better UX (ensures main thread)
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.showLoading { [weak self] in
        self?.hide()
      }
    }

    // Collect clickable elements in background to avoid blocking UI
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }

      // Collect elements on background thread
      let elements = AXHelpers.collectClickableElements()

      // Update UI on main thread with proper state management
      DispatchQueue.main.async {
        // Double-check overlay is still visible (user might have dismissed during collection)
        guard self.isVisible else {
          return
        }
        self.updateOverlayWithElements(elements)
      }
    }
  }

  /// Hides and dismisses the overlay
  func hide() {
    // Ensure UI updates happen on main thread
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.window?.orderOut(nil)
      self.window = nil
      self.keyboardCoordinator = nil
    }
  }

  /// Brings the overlay to front if it exists
  func bringToFront() {
    window?.orderFrontRegardless()
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
      windowNumber: 0,
      context: nil,
      characters: characters ?? "",
      charactersIgnoringModifiers: characters ?? "",
      isARepeat: false,
      keyCode: UInt16(keyCode)
    )

    guard let event = event else { return false }

    return coordinator.handleKeyEvent(event)
  }

  // MARK: - Private Methods

  /// Shows loading overlay on the screen containing the mouse cursor
  /// Must be called on the main thread
  private func showLoading(onDismiss: @escaping () -> Void) {
    // Ensure we're on main thread for UI updates
    guard Thread.isMainThread else {
      DispatchQueue.main.async {
        self.showLoading(onDismiss: onDismiss)
      }
      return
    }

    // Get mouse location to find which screen to show overlay on
    let mouseLocation = NSEvent.mouseLocation
    let targetScreen =
      NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main

    guard let screen = targetScreen else {
      debugLog("No screen found")
      return
    }

    debugLog("Creating overlay on screen: \(screen.frame), mouse at: \(mouseLocation)")

    let contentView = LoadingOverlayView(onDismiss: onDismiss)
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

    debugLog("Window created at: \(window.frame)")
  }

  /// Updates the overlay UI with collected elements
  /// This method is called on the main thread after elements are collected
  private func updateOverlayWithElements(_ elements: [ClickableElement]) {
    // Ensure we're still visible (user might have dismissed during collection)
    guard isVisible else {
      return
    }

    // Create keyboard event coordinator
    let keyboardCoordinator = KeyboardInputCoordinator(
      elements: elements,
      onElementClick: { [weak self] element in
        self?.clickElement(element)
      },
      onDismiss: { [weak self] in
        self?.hide()
      }
    )
    self.keyboardCoordinator = keyboardCoordinator

    // Update overlay with elements
    update(
      elements: elements,
      keyboardCoordinator: keyboardCoordinator,
      onElementClick: { [weak self] element in
        self?.clickElement(element)
      },
      onDismiss: { [weak self] in
        self?.hide()
      }
    )
  }

  /// Performs a click action on the given element
  private func clickElement(_ element: ClickableElement) {
    let success = AXHelpers.clickElement(element)

    if success {
      // Hide overlay after successful click with brief delay for visual feedback
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.hide()
      }
    }
  }

  /// Updates the overlay with clickable elements
  /// Must be called on the main thread
  private func update(
    elements: [ClickableElement],
    keyboardCoordinator: KeyboardInputCoordinator,
    onElementClick: @escaping (ClickableElement) -> Void,
    onDismiss: @escaping () -> Void
  ) {
    // Ensure we're on main thread for UI updates
    guard Thread.isMainThread else {
      DispatchQueue.main.async {
        self.update(
          elements: elements, keyboardCoordinator: keyboardCoordinator,
          onElementClick: onElementClick, onDismiss: onDismiss)
      }
      return
    }

    guard let window = self.window, let screen = window.screen else {
      debugLog("No window or screen available")
      return
    }

    let screenFrame = screen.frame

    // The screen with the menu bar is always index 0 (the primary display)
    // This is the most reliable way to detect the primary screen
    let isPrimaryScreen = (screen == NSScreen.screens[0])

    debugLog("Overlay on screen: \(screenFrame), found \(elements.count) elements")

    let windowFrame = window.frame

    debugLog("Window frame: \(windowFrame)")
    debugLog("Screen frame: \(screenFrame), window screen: \(window.screen?.frame ?? .zero)")

    // Log element positions for debugging
    for (index, element) in elements.enumerated() {
      debugLog("Element \(index + 1) '\(element.title)' at global: \(element.frame)")
    }

    // Create the overlay view with keyboard input handling
    let overlayView = AccessibilityOverlayView(
      elements: elements,
      windowFrame: windowFrame,
      windowHeight: windowFrame.height,
      isPrimaryScreen: isPrimaryScreen,
      keyboardCoordinator: keyboardCoordinator,
      onElementClick: onElementClick,
      onDismiss: onDismiss
    )
    let hostingView = NSHostingView(rootView: overlayView)

    // Update window content (we're already on main thread)
    window.contentView = hostingView
    debugLog("Overlay view updated with \(elements.count) elements")
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

        Text("Scanning for links and buttons...")
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
  private var matchingElements: [(index: Int, element: ClickableElement, hint: String)] {
    keyboardCoordinator.getMatchingElements(for: keyboardCoordinator.typedPrefix)
  }

  // Elements to display: all if no prefix, only matching if prefix exists
  private var elementsToDisplay: [(index: Int, element: ClickableElement, hint: String)] {
    if keyboardCoordinator.typedPrefix.isEmpty {
      return elements.enumerated().compactMap { offset, element in
        guard let hint = keyboardCoordinator.getHint(forIndex: offset) else { return nil }
        return (index: offset, element: element, hint: hint)
      }
    }
    return matchingElements
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        // Semi-transparent background that can be clicked to dismiss
        Color.black.opacity(0.3)
          .frame(width: geometry.size.width, height: geometry.size.height)
          .contentShape(Rectangle())
          .onTapGesture {
            debugLog("Background tapped")
            onDismiss()
          }

        // Hint badges for each element (only show matching ones when prefix is typed)
        ForEach(Array(elementsToDisplay), id: \.element.id) { item in
          let elementIndex = item.index
          let element = item.element
          let hint = item.hint
          let typedPrefix = keyboardCoordinator.typedPrefix
          let isMatching = matchingElements.contains { $0.index == elementIndex }
          let matchedPrefixLength =
            typedPrefix.isEmpty
            ? 0 : (hint.hasPrefix(typedPrefix) ? typedPrefix.count : 0)

          elementHint(
            for: element,
            hint: hint,
            geometrySize: geometry.size,
            isMatching: isMatching,
            matchedPrefixLength: matchedPrefixLength
          )
        }

        // Instructions banner
        instructionsBanner
      }
    }
    .edgesIgnoringSafeArea(.all)
  }

  // MARK: - View Components

  /// Creates a hint badge at the top-left corner of an element with liquid glass effect
  private func elementHint(
    for element: ClickableElement,
    hint: String,
    geometrySize: CGSize,
    isMatching: Bool,
    matchedPrefixLength: Int
  ) -> some View {
    let minHintSize: CGFloat = 14
    let hintString = hint

    // COORDINATE SYSTEM CONVERSION:
    // Accessibility API (kAXPositionAttribute) uses TOP-LEFT origin
    // NSWindow.frame uses BOTTOM-LEFT origin
    // SwiftUI uses TOP-LEFT origin
    //
    // Conversion steps:
    // 1. X: Direct conversion (same horizontal system)
    // 2. Y: Convert window frame from bottom-left to top-left, then calculate relative position
    // Position hint at the top-left corner of the element
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
    let elementTopYInTopLeft = element.frame.minY  // Element top in top-left origin
    let elementTopYRelativeToWindow = elementTopYInTopLeft - windowTopYInTopLeft

    // Debug logging for coordinate conversion (first hint only to avoid spam)
    if hint == keyboardCoordinator.getHint(forIndex: 0) {
      debugLog("Coordinate conversion for element '\(hint)' ('\(element.title)'):")
      debugLog("  Element frame (global, top-left origin): \(element.frame)")
      debugLog("  Window frame (global, bottom-left origin): \(windowFrame)")
      debugLog("  Primary screen height: \(primaryScreenHeight)")
      debugLog("  Window top in top-left origin: \(windowTopYInTopLeft)")
      debugLog("  Element top in top-left origin: \(elementTopYInTopLeft)")
      debugLog("  Element top Y relative to window top: \(elementTopYRelativeToWindow)")
      debugLog(
        "  Calculated viewX: \(viewX), viewY: \(elementTopYRelativeToWindow) (top-left origin)"
      )
      debugLog("  Geometry size: \(geometrySize)")
    }

    // Use .position() for absolute positioning within the geometry
    // .position() sets the CENTER of the view at the given coordinates
    // X: Position hint center at left edge (minX) by adding half minimum hint size
    // Y: Position hint center at top edge (minY) by adding half minimum hint size
    // Note: The badge will expand from center, so multi-digit numbers will grow appropriately
    let posX = viewX + minHintSize / 2
    let posY = elementTopYRelativeToWindow + minHintSize / 2

    // Hint label content
    let textContent: some View = Group {
      if matchedPrefixLength > 0 && matchedPrefixLength < hintString.count {
        // Show matched prefix in different color
        HStack(spacing: 0) {
          Text(String(hintString.prefix(matchedPrefixLength)))
            .font(.system(size: 14, weight: .regular))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)

          Text(String(hintString.dropFirst(matchedPrefixLength)))
            .font(.system(size: 14, weight: .regular))
            .foregroundColor(.yellow)
            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
        }
      } else {
        Text(hintString)
          .font(.system(size: 14, weight: .regular))
          .foregroundColor(.white)
          .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
      }
    }

    return
      textContent
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .frame(minWidth: minHintSize, minHeight: minHintSize)
      .background(
        ZStack {
          // Base blur layer
          RoundedRectangle(cornerRadius: 3)
            .fill(.ultraThinMaterial)

          // Color tint layer
          RoundedRectangle(cornerRadius: 3)
            .fill(isMatching ? Color.orange.opacity(0.3) : Color.blue.opacity(0.3))

          // Subtle highlight for glass effect
          RoundedRectangle(cornerRadius: 3)
            .fill(
              LinearGradient(
                colors: [
                  Color.white.opacity(0.3),
                  Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )

          // Border
          RoundedRectangle(cornerRadius: 3)
            .strokeBorder(
              isMatching ? Color.orange.opacity(0.6) : Color.white.opacity(0.5),
              lineWidth: 0.5
            )
        }
        .shadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1)
      )
      .fixedSize()
      .position(x: posX, y: posY)
      .opacity(element.isEnabled ? 1.0 : 0.4)
      .contentShape(Rectangle())
      .onTapGesture {
        debugLog("Tapped hint '\(hint)' for '\(element.title)'")
        onElementClick(element)
      }
  }

  /// Instructions banner at the top of the overlay
  private var instructionsBanner: some View {
    VStack {
      HStack {
        Spacer()
        VStack(spacing: 4) {
          Text("Press ESC to dismiss")
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

  // MARK: - Helpers

}
