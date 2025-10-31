import ApplicationServices
import Cocoa

/// Manages smooth scrolling using AX API increment/decrement actions
/// Performs discrete scroll steps on the focused scrollbar element
class SmoothScrollManager {
  static let shared = SmoothScrollManager()

  private var scrollTimer: Timer?
  private var remainingSteps: Int = 0
  private var isScrolling: Bool = false
  private var scrollDirection: Int = 0  // 1 for up, -1 for down
  private let scrollQueue = DispatchQueue(label: "com.kbdcmd.smoothscroll", qos: .userInteractive)

  // Scrolling parameters
  private let scrollInterval: TimeInterval = 0.02  // 50ms between steps
  private let stepsPerUnit: Int = 3  // 3 scroll steps per unit

  // Target scrollbar element (captured once at start)
  private var targetScrollBar: AXUIElement?

  private init() {}

  // MARK: - Scroll Management

  /// Request a scroll operation. If scrolling is already in progress, accumulate the request.
  /// - Parameter scrollUnits: Number of scroll units (positive = up, negative = down)
  func scrollUnits(_ scrollUnits: Int32) {
    scrollQueue.async { [weak self] in
      guard let self = self else { return }

      // Convert scroll units to steps
      let steps = Int(scrollUnits) * self.stepsPerUnit
      
      // Accumulate scroll steps
      self.remainingSteps += steps
      self.scrollDirection = steps > 0 ? 1 : -1

      // Capture target scrollbar if not already scrolling
      if !self.isScrolling {
        DispatchQueue.main.sync {
          self.captureScrollBar()
        }
      }

      // Always try to start scrolling
      self.startContinuousScroll()
    }
  }

  /// Find and capture the vertical scrollbar of the focused element
  private func captureScrollBar() {
    targetScrollBar = nil

    // Get focused element
    let systemWide = AXUIElementCreateSystemWide()
    var focusedElement: AnyObject?
    var result = AXUIElementCopyAttributeValue(
      systemWide,
      kAXFocusedUIElementAttribute as CFString,
      &focusedElement
    )

    if result != .success {
      // Try frontmost window
      guard let frontApp = NSWorkspace.shared.frontmostApplication else {
        print("DEBUG: No frontmost application")
        return
      }
      let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
      result = AXUIElementCopyAttributeValue(
        appElement,
        kAXFocusedWindowAttribute as CFString,
        &focusedElement
      )
      if result != .success {
        print("DEBUG: Could not get focused element")
        return
      }
    }

    guard let element = focusedElement as! AXUIElement? else {
      print("DEBUG: No focused element")
      return
    }

    // Walk up hierarchy to find scrollbar
    var current: AXUIElement? = element
    var visited = Set<UnsafeRawPointer>()

    while let elem = current {
      let ptr = UnsafeRawPointer(Unmanaged.passUnretained(elem).toOpaque())
      if visited.contains(ptr) { break }
      visited.insert(ptr)

      // Check for vertical scrollbar
      var vScrollBar: AnyObject?
      if AXUIElementCopyAttributeValue(
        elem, kAXVerticalScrollBarAttribute as CFString, &vScrollBar) == .success,
        let scrollBar = vScrollBar as! AXUIElement?
      {
        targetScrollBar = scrollBar
        print("DEBUG: Found vertical scrollbar")
        return
      }

      // Try parent
      var parent: AnyObject?
      if AXUIElementCopyAttributeValue(elem, kAXParentAttribute as CFString, &parent) == .success {
        current = parent as! AXUIElement?
      } else {
        current = nil
      }
    }

    print("DEBUG: No scrollbar found")
  }

  /// Stop continuous scrolling
  func stop() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }

      self.scrollTimer?.invalidate()
      self.scrollTimer = nil
      self.isScrolling = false

      self.scrollQueue.async {
        self.remainingSteps = 0
        self.targetScrollBar = nil
      }
    }
  }

  private func startContinuousScroll() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.isScrolling else { return }

      self.isScrolling = true
      self.scrollTimer?.invalidate()

      self.scrollTimer = Timer(timeInterval: self.scrollInterval, repeats: true) { [weak self] _ in
        self?.performScrollStep()
      }

      RunLoop.main.add(self.scrollTimer!, forMode: .common)
    }
  }

  private func performScrollStep() {
    scrollQueue.async { [weak self] in
      guard let self = self else { return }

      // Check if we have steps to scroll
      guard abs(self.remainingSteps) > 0 else {
        DispatchQueue.main.async {
          self.scrollTimer?.invalidate()
          self.scrollTimer = nil
          self.isScrolling = false
        }
        self.targetScrollBar = nil
        return
      }

      // Perform one scroll step
      DispatchQueue.main.async {
        self.performScrollAction()
      }

      // Decrement remaining steps
      if self.remainingSteps > 0 {
        self.remainingSteps -= 1
      } else {
        self.remainingSteps += 1
      }
    }
  }

  /// Perform a single scroll increment or decrement action
  private func performScrollAction() {
    guard let scrollBar = targetScrollBar else {
      return
    }

    let action = scrollDirection > 0 ? kAXIncrementAction : kAXDecrementAction
    let result = AXUIElementPerformAction(scrollBar, action as CFString)
    
    if result != .success {
      print("DEBUG: Scroll action failed: \(result.rawValue)")
    }
  }
}

/// Legacy function for backward compatibility
/// - Parameter pixels: Number of pixels to scroll (positive = up, negative = down)
func simulateSmoothScroll(pixels: Int32) {
  // Convert pixels to scroll units (1 unit = 100 pixels)
  let units = Int32(Double(pixels) / 100.0)
  SmoothScrollManager.shared.scrollUnits(units)
}
