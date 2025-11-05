import AppKit
import Foundation
import QuartzCore

/// Provides display-link driven animations synchronized with the display refresh cycle.
///
/// This class manages `CADisplayLink` resources efficiently:
/// - Display link is created lazily when first animation starts
/// - Link is paused (not invalidated) when animations complete to allow quick restart
/// - Link is fully invalidated after 5 seconds of inactivity to free resources
/// - All operations automatically dispatch to main thread
///
/// ## Usage
/// ```swift
/// // Timed animation with progress from 0.0 to 1.0
/// DisplayLinkAnimator.shared.animate(duration: 0.3) { progress in
///   updateUI(progress)
/// }
///
/// // Continuous loop receiving timestamp and frame duration
/// DisplayLinkAnimator.shared.startLoop { timestamp, delta in
///   updateAnimation(delta)
/// }
///
/// // Stop any running animation
/// DisplayLinkAnimator.shared.stop()
/// ```
final class DisplayLinkAnimator {
  static let shared = DisplayLinkAnimator()

  /// Duration of inactivity before display link resources are released
  private static let idleCleanupDelay: TimeInterval = 5.0

  private enum State {
    case timed(TimedAnimation)
    case loop(LoopAnimation)
  }

  private final class TimedAnimation {
    let duration: TimeInterval
    var startTime: CFTimeInterval?
    let frameHandler: (Double) -> Void
    let completionHandler: (() -> Void)?

    init(
      duration: TimeInterval,
      frameHandler: @escaping (Double) -> Void,
      completionHandler: (() -> Void)?
    ) {
      self.duration = duration
      self.startTime = nil
      self.frameHandler = frameHandler
      self.completionHandler = completionHandler
    }
  }

  private final class LoopAnimation {
    var frameHandler: (CFTimeInterval, CFTimeInterval) -> Void

    init(frameHandler: @escaping (CFTimeInterval, CFTimeInterval) -> Void) {
      self.frameHandler = frameHandler
    }
  }

  private var displayLink: CADisplayLink?
  private var state: State?
  private var cleanupWorkItem: DispatchWorkItem?

  private init() {}

  /// Starts a timed animation that runs for the specified duration.
  ///
  /// The frame handler is called on each display refresh with a progress value from 0.0 to 1.0.
  /// If duration is 0 or negative, the frame handler is called once with progress 1.0.
  ///
  /// - Parameters:
  ///   - duration: How long the animation should run
  ///   - frame: Called each frame with progress from 0.0 to 1.0
  ///   - completion: Called when animation completes
  func animate(
    duration: TimeInterval,
    frame: @escaping (Double) -> Void,
    completion: (() -> Void)? = nil
  ) {
    performOnMain {
      // Cancel any pending cleanup since we're starting new work
      self.cancelCleanup()

      guard duration > 0 else {
        frame(1.0)
        completion?()
        return
      }

      // Stop existing animation if any
      self.pauseDisplayLink()

      let animation = TimedAnimation(
        duration: duration,
        frameHandler: frame,
        completionHandler: completion
      )

      self.state = .timed(animation)
      guard let link = self.configureDisplayLink() else {
        self.state = nil
        frame(1.0)
        completion?()
        return
      }

      link.isPaused = false
      animation.startTime = nil
    }
  }

  /// Starts or updates a continuous display-synchronized loop.
  ///
  /// The frame handler is called on each display refresh with the current timestamp
  /// and frame duration. If a loop is already running, only the handler is updated.
  /// The loop continues indefinitely until `stop()` is called.
  ///
  /// - Parameter frame: Called each frame with (timestamp, frameDuration)
  func startLoop(frame: @escaping (CFTimeInterval, CFTimeInterval) -> Void) {
    performOnMain {
      // Cancel any pending cleanup since we're starting new work
      self.cancelCleanup()

      // If already in loop mode, just update the handler and ensure link is running
      if case .loop(let loop)? = self.state {
        loop.frameHandler = frame
        guard let link = self.configureDisplayLink() else {
          return
        }

        if link.isPaused {
          link.isPaused = false
        }
        return
      }

      // Stop any existing animation
      self.pauseDisplayLink()
      self.state = .loop(LoopAnimation(frameHandler: frame))

      guard let link = self.configureDisplayLink() else {
        self.state = nil
        return
      }

      link.isPaused = false
    }
  }

  /// Stops any running animation or loop immediately.
  ///
  /// This pauses the display link and schedules cleanup after 5 seconds of inactivity.
  func stop() {
    performOnMain {
      self.pauseDisplayLink()
      self.scheduleCleanup()
    }
  }

  /// Configures and returns the display link, creating it lazily if needed.
  ///
  /// - Returns: The display link, or nil if no screen is available
  private func configureDisplayLink() -> CADisplayLink? {
    if let link = displayLink {
      return link
    }

    guard let screen = NSScreen.main else {
      return nil
    }

    let link = screen.displayLink(target: self, selector: #selector(handleDisplayLink(_:)))
    link.add(to: .main, forMode: .common)
    displayLink = link
    return link
  }

  /// Pauses the display link and clears animation state without releasing resources.
  private func pauseDisplayLink() {
    displayLink?.isPaused = true
    state = nil
  }

  /// Fully releases display link resources.
  private func invalidateDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
    state = nil
  }

  /// Cancels any scheduled cleanup work.
  private func cancelCleanup() {
    cleanupWorkItem?.cancel()
    cleanupWorkItem = nil
  }

  /// Schedules display link cleanup after idle delay if no animation is active.
  private func scheduleCleanup() {
    cancelCleanup()

    let workItem = DispatchWorkItem { [weak self] in
      self?.invalidateDisplayLink()
    }

    cleanupWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.idleCleanupDelay,
      execute: workItem
    )
  }

  /// Ensures work executes on the main thread.
  private func performOnMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  /// Display link callback invoked each frame while animations are running.
  @objc private func handleDisplayLink(_ link: CADisplayLink) {
    guard let currentState = state else {
      // No active animation - link should be paused but handle gracefully
      return
    }

    let timestamp = link.timestamp
    let frameDuration = link.targetTimestamp - timestamp

    switch currentState {
    case .timed(let animation):
      // Initialize start time on first frame
      if animation.startTime == nil {
        animation.startTime = timestamp
      }

      guard let startTime = animation.startTime else {
        return
      }

      let elapsed = timestamp - startTime
      let progress = min(1.0, elapsed / animation.duration)

      animation.frameHandler(progress)

      // Animation complete - pause link and schedule cleanup
      if progress >= 1.0 {
        let completion = animation.completionHandler
        state = nil
        link.isPaused = true
        scheduleCleanup()
        completion?()
      }

    case .loop(let loop):
      loop.frameHandler(timestamp, frameDuration)
    }
  }
}
