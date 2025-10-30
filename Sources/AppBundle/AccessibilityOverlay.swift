import Cocoa

/// Manages the accessibility overlay that highlights clickable elements
/// Activated via RCMD+O keyboard shortcut
/// 
/// This class coordinates between:
/// - AXHelpers: Collects clickable elements from accessibility API
/// - HintOverlay: Manages UI window and views
/// - KeyboardInputCoordinator: Handles keyboard input for element selection
class AccessibilityOverlay: NSObject {
  static let shared = AccessibilityOverlay()
  
  private let hintOverlay = HintOverlay()
  private var keyboardCoordinator: KeyboardInputCoordinator?
  
  private override init() {
    super.init()
  }
  
  // MARK: - Public Interface
  
  func show() {
    // If already visible, bring to front
    guard !hintOverlay.isVisible else {
      hintOverlay.bringToFront()
      return
    }
    
    // Show loading indicator immediately for better UX (ensures main thread)
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.hintOverlay.showLoading { [weak self] in
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
        guard self.hintOverlay.isVisible else {
          return
        }
        self.updateOverlayWithElements(elements)
      }
    }
  }
  
  func hide() {
    // Ensure UI updates happen on main thread
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.hintOverlay.hide()
      self.keyboardCoordinator = nil
    }
  }
  
  func isVisible() -> Bool {
    return hintOverlay.isVisible
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
  
  /// Updates the overlay UI with collected elements
  /// This method is called on the main thread after elements are collected
  private func updateOverlayWithElements(_ elements: [ClickableElement]) {
    // Ensure we're still visible (user might have dismissed during collection)
    guard hintOverlay.isVisible else {
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
    hintOverlay.update(
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
}
