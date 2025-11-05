import CoreVideo
import Darwin
import Foundation

/// Provides display-link driven animations similar to requestAnimationFrame on the web.
///
/// Note: This class uses CVDisplayLink which was deprecated in macOS 15.
/// The new recommended APIs (NSView/NSWindow/NSScreen.displayLink) require a different
/// architecture with view/window references. CVDisplayLink continues to work correctly
/// and this can be refactored later if needed.
final class DisplayLinkAnimator {
  static let shared = DisplayLinkAnimator()

  private enum State {
    case timed(TimedAnimation)
    case loop(LoopAnimation)
  }

  private final class TimedAnimation {
    var duration: TimeInterval
    var preferredFrameInterval: TimeInterval
    var startTime: Double?
    var lastFrameTime: Double?
    let frameHandler: (Double) -> Void
    let completionHandler: (() -> Void)?

    init(
      duration: TimeInterval,
      preferredFrameInterval: TimeInterval,
      frameHandler: @escaping (Double) -> Void,
      completionHandler: (() -> Void)?
    ) {
      self.duration = duration
      self.preferredFrameInterval = preferredFrameInterval
      self.startTime = nil
      self.lastFrameTime = nil
      self.frameHandler = frameHandler
      self.completionHandler = completionHandler
    }
  }

  private final class LoopAnimation {
    var preferredFrameInterval: TimeInterval
    var lastFrameTime: Double?
    var frameHandler: (Double, Double) -> Void

    init(preferredFrameInterval: TimeInterval, frameHandler: @escaping (Double, Double) -> Void) {
      self.preferredFrameInterval = preferredFrameInterval
      self.lastFrameTime = nil
      self.frameHandler = frameHandler
    }
  }

  private let syncQueue = DispatchQueue(label: "com.kbdcmd.display-link", qos: .userInteractive)
  private var displayLink: CVDisplayLink?
  private var state: State?

  private init() {
    setupDisplayLink()
  }

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

    syncQueue.sync {
      ensureDisplayLink()

      guard let link = displayLink else {
        DispatchQueue.main.async {
          frame(1.0)
          completion?()
        }
        return
      }

      stopLocked()

      let animation = TimedAnimation(
        duration: duration,
        preferredFrameInterval: 1.0 / Double(max(1, preferredFPS)),
        frameHandler: frame,
        completionHandler: completion
      )

      state = .timed(animation)
      CVDisplayLinkStart(link)  // Deprecated in macOS 15 - still functional
    }
  }

  /// Starts (or updates) a continuous display-link loop.
  func startLoop(preferredFPS: Int = 120, frame: @escaping (Double, Double) -> Void) {
    syncQueue.sync {
      ensureDisplayLink()

      guard let link = displayLink else {
        return
      }

      let interval = 1.0 / Double(max(1, preferredFPS))

      if case .loop(let loop)? = state {
        loop.frameHandler = frame
        loop.preferredFrameInterval = interval
        if !CVDisplayLinkIsRunning(link) {  // Deprecated in macOS 15 - still functional
          loop.lastFrameTime = nil
          CVDisplayLinkStart(link)  // Deprecated in macOS 15 - still functional
        }
        return
      }

      stopLocked()

      let loop = LoopAnimation(preferredFrameInterval: interval, frameHandler: frame)
      state = .loop(loop)
      CVDisplayLinkStart(link)  // Deprecated in macOS 15 - still functional
    }
  }

  /// Stops any running animation or loop.
  func stop() {
    syncQueue.sync {
      stopLocked()
    }
  }

  private func stopLocked() {
    if let link = displayLink, CVDisplayLinkIsRunning(link) {  // Deprecated in macOS 15 - still functional
      CVDisplayLinkStop(link)  // Deprecated in macOS 15 - still functional
    }
    state = nil
  }

  private func ensureDisplayLink() {
    if displayLink == nil {
      setupDisplayLink()
    }
  }

  private func setupDisplayLink() {
    var link: CVDisplayLink?
    // Deprecated in macOS 15 - still functional, refactor to NSScreen.displayLink in future
    guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
      let displayLink = link
    else {
      return
    }

    CVDisplayLinkSetCurrentCGDisplay(displayLink, CGMainDisplayID())

    let callback: CVDisplayLinkOutputCallback = {
      (
        _: CVDisplayLink,
        _: UnsafePointer<CVTimeStamp>,
        inOutputTime: UnsafePointer<CVTimeStamp>,
        _: CVOptionFlags,
        _: UnsafeMutablePointer<CVOptionFlags>,
        displayLinkContext: UnsafeMutableRawPointer?
      ) -> CVReturn in

      guard let context = displayLinkContext else {
        return kCVReturnError
      }

      let animator = Unmanaged<DisplayLinkAnimator>
        .fromOpaque(context)
        .takeUnretainedValue()
      return animator.handleDisplayLink(timestamp: inOutputTime.pointee)
    }

    CVDisplayLinkSetOutputCallback(  // Deprecated in macOS 15 - still functional
      displayLink,
      callback,
      UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

    self.displayLink = displayLink
  }

  private func handleDisplayLink(timestamp: CVTimeStamp) -> CVReturn {
    var timedFrame: ((Double) -> Void)?
    var timedCompletion: (() -> Void)?
    var timedProgress: Double = 0
    var loopFrame: ((Double, Double) -> Void)?
    var loopTimestamp: Double = 0
    var loopDelta: Double = 0
    var shouldSkip = false

    syncQueue.sync {
      guard let link = displayLink, let currentState = state else {
        shouldSkip = true
        return
      }

      let currentTime = Self.seconds(for: timestamp.hostTime)

      switch currentState {
      case .timed(let animation):
        if animation.startTime == nil {
          animation.startTime = currentTime
          animation.lastFrameTime = currentTime - animation.preferredFrameInterval
        }

        guard let startTime = animation.startTime else {
          shouldSkip = true
          return
        }

        if let last = animation.lastFrameTime,
          currentTime - last < animation.preferredFrameInterval
        {
          shouldSkip = true
          return
        }

        let elapsed = currentTime - startTime
        timedProgress = min(1.0, elapsed / animation.duration)

        animation.lastFrameTime = currentTime
        timedFrame = animation.frameHandler

        if timedProgress >= 1.0 {
          timedCompletion = animation.completionHandler
          state = nil
          CVDisplayLinkStop(link)  // Deprecated in macOS 15 - still functional
        }

      case .loop(let loop):
        if let last = loop.lastFrameTime,
          currentTime - last < loop.preferredFrameInterval
        {
          shouldSkip = true
          return
        }

        let delta = loop.lastFrameTime.map { currentTime - $0 } ?? loop.preferredFrameInterval
        loop.lastFrameTime = currentTime

        loopFrame = loop.frameHandler
        loopTimestamp = currentTime
        loopDelta = delta
      }
    }

    if shouldSkip {
      return kCVReturnSuccess
    }

    if let frame = timedFrame {
      DispatchQueue.main.async {
        frame(timedProgress)
      }
    }

    if let completion = timedCompletion {
      DispatchQueue.main.async {
        completion()
      }
    }

    if let loop = loopFrame {
      DispatchQueue.main.async {
        loop(loopTimestamp, loopDelta)
      }
    }

    return kCVReturnSuccess
  }

  private static let timebaseInfo: mach_timebase_info = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
  }()

  private static func seconds(for hostTime: UInt64) -> Double {
    let info = timebaseInfo
    let nanos = Double(hostTime) * Double(info.numer) / Double(info.denom)
    return nanos / 1_000_000_000
  }
}
