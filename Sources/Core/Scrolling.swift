import ApplicationServices
import Cocoa

/// Manages smooth scrolling functionality using CGEvent scroll wheel simulation
public class Scrolling {
  public static let shared = Scrolling()

  private init() {}

  private final class ScrollAnimationState {
    var target: Double = 0
    var delivered: Double = 0
    var pending: Double = 0
    var velocity: Double = 0
    var baseSpeed: Double
    var maxVelocity: Double
    var stopDeceleration: Double

    init(baseSpeed: Double) {
      self.baseSpeed = 0
      self.maxVelocity = 720
      self.stopDeceleration = self.maxVelocity / 0.12
      resetDynamics(to: baseSpeed)
    }

    func resetDynamics(to hint: Double) {
      let clampedSpeed = max(240, min(900, hint))
      baseSpeed = clampedSpeed
      maxVelocity = max(720, min(1200, clampedSpeed * 1.8))
      stopDeceleration = maxVelocity / 0.12
    }

    func updateDynamics(with hint: Double) {
      let clampedSpeed = max(240, min(900, hint))
      baseSpeed = (baseSpeed * 0.6) + (clampedSpeed * 0.4)
      maxVelocity = max(720, min(1200, baseSpeed * 1.8))
      stopDeceleration = maxVelocity / 0.12
    }
  }

  private var animationState: ScrollAnimationState?
  private lazy var loopHandler: (CFTimeInterval, CFTimeInterval) -> Void = { [weak self] _, delta in
    self?.handleLoopFrame(delta: delta)
  }

  /// Scrolls by the specified number of units
  /// - Parameters:
  ///   - amount: Positive values scroll up, negative values scroll down
  ///   - units: Scroll unit type (line or pixel), defaults to .line
  func scroll(_ amount: Int, units: CGScrollEventUnit = .line) {
    guard
      let event = CGEvent(
        scrollWheelEvent2Source: nil,
        units: units,
        wheelCount: 1,
        wheel1: Int32(amount),
        wheel2: 0,
        wheel3: 0
      )
    else {
      return
    }

    event.post(tap: .cghidEventTap)
  }

  /// Scrolls down by the specified number of units
  /// - Parameter units: Number of units to scroll (positive value)
  func scrollDown(_ units: Int = 10) {
    scroll(-abs(units))
  }

  /// Scrolls up by the specified number of units
  /// - Parameter units: Number of units to scroll (positive value)
  func scrollUp(_ units: Int = 10) {
    scroll(abs(units))
  }

  /// Performs smooth continuous scrolling that remains fluid when additional requests arrive.
  /// - Parameters:
  ///   - amount: Total pixels to scroll. Positive scrolls up, negative scrolls down
  ///   - duration: Base animation time hint used to calibrate scrolling speed
  public func smoothScroll(_ amount: Int, duration: TimeInterval = 0.20) {
    guard amount != 0 else { return }

    let safeDuration = max(duration, 0.01)
    DispatchQueue.main.async {
      self.enqueueScroll(amount: amount, duration: safeDuration)
    }
  }

  private func enqueueScroll(amount: Int, duration: TimeInterval) {
    let magnitude = Double(abs(amount))
    let speedHint = magnitude / duration
    let amountDouble = Double(amount)

    if let state = animationState {
      let previousRemaining = state.target - state.delivered
      if previousRemaining * amountDouble < 0 {
        state.target = state.delivered + amountDouble
        state.velocity = 0
        state.pending = 0
      } else {
        state.target += amountDouble
        let newRemaining = state.target - state.delivered
        if previousRemaining.sign != newRemaining.sign {
          state.velocity = 0
          state.pending = 0
        }
      }

      state.updateDynamics(with: speedHint)

      DisplayLinkAnimator.shared.startLoop(frame: loopHandler)
      return
    }

    let state = ScrollAnimationState(baseSpeed: speedHint)
    state.target = Double(amount)
    animationState = state

    DisplayLinkAnimator.shared.startLoop(frame: loopHandler)
  }

  private func handleLoopFrame(delta: Double) {
    guard let state = animationState else {
      DisplayLinkAnimator.shared.stop()
      return
    }

    let clampedDelta = max(1.0 / 480.0, min(delta, 1.0 / 30.0))
    let remaining = state.target - state.delivered

    if abs(remaining) < 0.001 && abs(state.velocity) < 0.001 {
      DisplayLinkAnimator.shared.stop()
      animationState = nil
      return
    }

    let response = max(12.0, min(32.0, state.baseSpeed / 36.0))
    let maximumVelocity = max(600.0, state.maxVelocity)
    let desiredVelocity = clamped(remaining * response, min: -maximumVelocity, max: maximumVelocity)
    let blend = min(1.0, response * clampedDelta * 1.35)
    state.velocity += (desiredVelocity - state.velocity) * blend

    if abs(remaining) < state.baseSpeed * 0.02 {
      applyStopDeceleration(state, delta: clampedDelta)
    }

    if remaining != 0, state.velocity != 0, (remaining > 0) != (state.velocity > 0) {
      applyStopDeceleration(state, delta: clampedDelta * 1.5)
    }

    let rawDelta = state.velocity * clampedDelta
    state.pending += rawDelta

    var emit = 0
    if abs(state.pending) >= 1.0 {
      emit = Int(state.pending.rounded(.towardZero))
    } else if abs(state.pending) >= 0.3 {
      emit = state.pending > 0 ? 1 : -1
    }

    if remaining > 0 {
      emit = min(emit, Int(floor(remaining)))
      if emit < 0 { emit = 0 }
    } else if remaining < 0 {
      emit = max(emit, Int(ceil(remaining)))
      if emit > 0 { emit = 0 }
    } else {
      emit = 0
    }

    if emit != 0 {
      state.pending -= Double(emit)
      state.delivered += Double(emit)
      scroll(emit, units: .pixel)
    }

    let residual = state.target - state.delivered
    if abs(residual) < 0.4 {
      state.pending = 0
    }

    if abs(residual) < 0.35 && abs(state.velocity) < 6 && abs(state.pending) < 0.25 {
      DisplayLinkAnimator.shared.stop()
      animationState = nil
    }
  }

  private func clamped(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
    return min(maxValue, max(minValue, value))
  }

  private func applyStopDeceleration(_ state: ScrollAnimationState, delta: Double) {
    guard state.velocity != 0 else { return }
    let drop = min(abs(state.velocity), state.stopDeceleration * delta)
    if drop <= 0 { return }
    state.velocity -= drop * (state.velocity > 0 ? 1 : -1)
    if abs(state.velocity) < 0.5 {
      state.velocity = 0
    }
  }
}
