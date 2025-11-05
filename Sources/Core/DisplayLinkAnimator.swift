import AppKit
import Foundation
import QuartzCore

/// Provides display-link driven animations similar to requestAnimationFrame on the web.
///
/// This class uses CADisplayLink (available in macOS 14+) to provide display-synchronized
/// animations. It supports both timed animations and continuous loops. All operations
/// automatically dispatch to the main thread if called from a background thread.
final class DisplayLinkAnimator {
  static let shared = DisplayLinkAnimator()

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

  private init() {}

  /// Starts an animation invoking `frame` on each display refresh until `duration` elapses.
  func animate(
    duration: TimeInterval,
    preferredFPS: Int = 120,
    frame: @escaping (Double) -> Void,
    completion: (() -> Void)? = nil
  ) {
    guard duration > 0 else {
      DispatchQueue.main.async {
        frame(1.0)
        completion?()
      }
      return
    }

    let work = {
      self.stopLocked()

      let animation = TimedAnimation(
        duration: duration,
        frameHandler: frame,
        completionHandler: completion
      )

      self.state = .timed(animation)
      self.ensureDisplayLink()
      let fps = Float(preferredFPS)
      self.displayLink?.preferredFrameRateRange = CAFrameRateRange(
        minimum: fps, maximum: fps, preferred: fps)
    }

    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  /// Starts (or updates) a continuous display-link loop.
  func startLoop(preferredFPS: Int = 120, frame: @escaping (CFTimeInterval, CFTimeInterval) -> Void)
  {
    let work = {
      let fps = Float(preferredFPS)
      let frameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)

      if case .loop(let loop)? = self.state {
        loop.frameHandler = frame
        self.displayLink?.preferredFrameRateRange = frameRateRange
        if self.displayLink?.isPaused ?? true {
          self.displayLink?.isPaused = false
        }
        return
      }

      self.stopLocked()

      let loop = LoopAnimation(frameHandler: frame)
      self.state = .loop(loop)
      self.ensureDisplayLink()
      self.displayLink?.preferredFrameRateRange = frameRateRange
    }

    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  /// Stops any running animation or loop.
  func stop() {
    let work = {
      self.stopLocked()
    }

    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  private func stopLocked() {
    displayLink?.invalidate()
    displayLink = nil
    state = nil
  }

  private func ensureDisplayLink() {
    guard displayLink == nil else { return }
    setupDisplayLink()
  }

  private func setupDisplayLink() {
    guard let screen = NSScreen.main else { return }

    let link = screen.displayLink(target: self, selector: #selector(handleDisplayLink(_:)))
    link.add(to: .main, forMode: .common)
    self.displayLink = link
  }

  @objc private func handleDisplayLink(_ link: CADisplayLink) {
    guard let currentState = state else {
      return
    }

    let timestamp = link.timestamp
    let targetTimestamp = link.targetTimestamp
    let frameDuration = targetTimestamp - timestamp

    switch currentState {
    case .timed(let animation):
      if animation.startTime == nil {
        animation.startTime = timestamp
      }

      guard let startTime = animation.startTime else {
        return
      }

      let elapsed = timestamp - startTime
      let progress = min(1.0, elapsed / animation.duration)

      animation.frameHandler(progress)

      if progress >= 1.0 {
        let completion = animation.completionHandler
        state = nil
        displayLink?.isPaused = true
        completion?()
      }

    case .loop(let loop):
      loop.frameHandler(timestamp, frameDuration)
    }
  }
}
