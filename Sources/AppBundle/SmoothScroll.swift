import ApplicationServices
import Cocoa

/// Manages smooth pixel-based scrolling with state tracking and continuous scroll support
/// Provides arrow-key-like smooth scrolling behavior
class SmoothScrollManager {
  static let shared = SmoothScrollManager()

  private var scrollTimer: Timer?
  private var accumulatedPixels: Double = 0.0
  private var isScrolling: Bool = false
  private let scrollQueue = DispatchQueue(label: "com.kbdcmd.smoothscroll", qos: .userInteractive)

  // Scrolling parameters optimized for smooth arrow-key-like behavior
  private let scrollInterval: TimeInterval = 0.016  // ~60fps (16.67ms)
  private let basePixelsPerFrame: Double = 3.0  // Base scroll speed
  private let scrollDuration: TimeInterval = 0.3  // Target duration for scrolling (300ms)

  // Scroll units to pixels conversion
  // 1 unit = 100 pixels of total scroll distance
  private let pixelsPerUnit: Double = 100.0

  private init() {}

  /// Request a scroll operation. If scrolling is already in progress, accumulate the request.
  /// - Parameter scrollUnits: Number of scroll units (positive = up, negative = down)
  ///   Each unit represents a scroll distance.
  ///   For example: 1 unit = 100 pixels, 10 units = 1000 pixels
  func scrollUnits(_ scrollUnits: Int32) {
    scrollQueue.async { [weak self] in
      guard let self = self else { return }

      // Convert scroll units to pixels
      let pixels = Double(scrollUnits) * self.pixelsPerUnit

      // Accumulate scroll requests
      self.accumulatedPixels += pixels

      // Always try to start scrolling - startContinuousScroll will check if already running
      self.startContinuousScroll()
    }
  }

  /// Stop continuous scrolling
  func stop() {
    // Timer must be invalidated on main thread
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }

      self.scrollTimer?.invalidate()
      self.scrollTimer = nil
      self.isScrolling = false

      // Clear accumulated pixels on background queue
      self.scrollQueue.async {
        self.accumulatedPixels = 0.0
      }
    }
  }

  private func startContinuousScroll() {
    // Timer must be created on main thread
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.isScrolling else { return }

      self.isScrolling = true

      // Cancel any existing timer
      self.scrollTimer?.invalidate()

      // Create a timer that fires at ~60fps for smooth scrolling
      self.scrollTimer = Timer(timeInterval: self.scrollInterval, repeats: true) { [weak self] _ in
        self?.performScrollStep()
      }

      // Use common modes to ensure timer fires during UI interactions
      RunLoop.main.add(self.scrollTimer!, forMode: .common)
    }
  }

  private func performScrollStep() {
    scrollQueue.async { [weak self] in
      guard let self = self else { return }

      // Check if we have pixels to scroll
      guard abs(self.accumulatedPixels) >= 0.5 else {
        // No pixels left, stop scrolling
        DispatchQueue.main.async {
          self.scrollTimer?.invalidate()
          self.scrollTimer = nil
          self.isScrolling = false
        }
        self.accumulatedPixels = 0.0
        return
      }

      // Calculate dynamic scroll speed based on accumulated pixels and target duration
      // More pixels = faster scrolling to complete in similar time
      let totalFrames = self.scrollDuration / self.scrollInterval
      let dynamicPixelsPerFrame = abs(self.accumulatedPixels) / totalFrames

      // Use the larger of base speed or dynamic speed for responsive feel
      let pixelsPerFrame = max(self.basePixelsPerFrame, dynamicPixelsPerFrame)

      // Determine scroll direction and amount for this frame
      let direction = self.accumulatedPixels > 0 ? 1.0 : -1.0
      let scrollAmount = min(abs(self.accumulatedPixels), pixelsPerFrame) * direction

      // Post the scroll event on main thread
      DispatchQueue.main.async {
        self.postScrollEvent(pixels: scrollAmount)
      }

      // Reduce accumulated pixels
      self.accumulatedPixels -= scrollAmount
    }
  }

  private func postScrollEvent(pixels: Double) {
    guard let eventSource = CGEventSource(stateID: .hidSystemState) else { return }

    // Get current mouse position for scroll event (convert from AppKit to Quartz coordinates)
    let mouseLocation = NSEvent.mouseLocation
    let screenHeight = NSScreen.main?.frame.height ?? 0
    let currentLocation = CGPoint(x: mouseLocation.x, y: screenHeight - mouseLocation.y)

    guard
      let scrollEvent = CGEvent(
        scrollWheelEvent2Source: eventSource,
        units: .pixel,
        wheelCount: 1,
        wheel1: Int32(pixels),
        wheel2: 0,
        wheel3: 0
      )
    else {
      return
    }

    scrollEvent.location = currentLocation
    scrollEvent.post(tap: .cghidEventTap)
  }
}

/// Legacy function for backward compatibility
/// - Parameter pixels: Number of pixels to scroll (positive = up, negative = down)
func simulateSmoothScroll(pixels: Int32) {
  // Convert pixels to scroll units (1 unit = 100 pixels)
  let units = Int32(Double(pixels) / 100.0)
  SmoothScrollManager.shared.scrollUnits(units)
}
